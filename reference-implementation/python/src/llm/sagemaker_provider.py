"""
SageMaker LLM Provider for AWS deployment.

This module provides the AWS-side LLM provider plus a monkey-patch installer
(`install()`) used by reference-implementation/python/entrypoint_aws.py to
auto-attach the provider to every LLMGateway created in the process. Importing
this module on a non-AWS container has no effect unless SAGEMAKER_ENDPOINT is
set, so the GCP path is unaffected.

Compatible with the HuggingFace Text Generation Inference (TGI) container
that AWS publishes for Llama 3 / Mistral on SageMaker — see
reference-implementation/terraform/aws/sagemaker.tf for the matching
deployment.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from typing import Any, Dict, List, Optional

from .gateway import LLMBackend, LLMGateway, LLMProvider, LLMResponse

logger = logging.getLogger(__name__)

SAGEMAKER_BACKEND = LLMBackend.SAGEMAKER


class SageMakerProvider(LLMProvider):
    """
    SageMaker-hosted LLM provider (Llama 3 70B / Mistral 7B via HuggingFace TGI).

    Reads config from environment variables (set by terraform/aws/ecs.tf):
      SAGEMAKER_ENDPOINT  — endpoint name (e.g. "project-303-rag-production-llm")
      SAGEMAKER_REGION    — AWS region (default: us-west-2)
      AWS_REGION          — fallback for SAGEMAKER_REGION

    Authenticates via the ECS task role (no explicit credentials needed in code).
    """

    def __init__(
        self,
        endpoint_name: Optional[str] = None,
        region: Optional[str] = None,
        model_label: str = "llama-3-70b",
    ):
        self.endpoint_name = endpoint_name or os.getenv("SAGEMAKER_ENDPOINT", "")
        self.region = (
            region
            or os.getenv("SAGEMAKER_REGION")
            or os.getenv("AWS_REGION")
            or "us-west-2"
        )
        self.model_label = model_label
        self._client = None

        if self.endpoint_name:
            self._init_client()

    def _init_client(self):
        try:
            import boto3  # type: ignore

            self._client = boto3.client("sagemaker-runtime", region_name=self.region)
            logger.info(
                f"SageMaker provider initialized | endpoint={self.endpoint_name} "
                f"region={self.region}"
            )
        except ImportError:
            logger.error(
                "boto3 not installed. Install with: pip install boto3 "
                "(already included in requirements-aws.txt)"
            )
            self._client = None
        except Exception as e:
            logger.error(f"Failed to initialize SageMaker runtime client: {e}")
            self._client = None

    def is_available(self) -> bool:
        return bool(self.endpoint_name and self._client is not None)

    @staticmethod
    def _build_tgi_payload(
        prompt: str,
        system_prompt: Optional[str],
        temperature: float,
        max_tokens: int,
    ) -> Dict[str, Any]:
        """
        Build a payload that matches the HuggingFace TGI inference schema.
        The Llama 3 chat template is applied client-side here for clarity
        (TGI also supports server-side via /chat, but /generate is more portable).
        """
        if system_prompt:
            # Llama 3 chat format (https://llama.meta.com/docs/model-cards-and-prompt-formats/meta-llama-3)
            formatted = (
                "<|begin_of_text|>"
                "<|start_header_id|>system<|end_header_id|>\n\n"
                f"{system_prompt}<|eot_id|>"
                "<|start_header_id|>user<|end_header_id|>\n\n"
                f"{prompt}<|eot_id|>"
                "<|start_header_id|>assistant<|end_header_id|>\n\n"
            )
        else:
            formatted = (
                "<|begin_of_text|>"
                "<|start_header_id|>user<|end_header_id|>\n\n"
                f"{prompt}<|eot_id|>"
                "<|start_header_id|>assistant<|end_header_id|>\n\n"
            )

        return {
            "inputs": formatted,
            "parameters": {
                "max_new_tokens": max_tokens,
                "temperature": max(temperature, 0.01),  # TGI requires > 0
                "top_p": 0.95,
                "do_sample": temperature > 0,
                "return_full_text": False,
                "stop": ["<|eot_id|>", "<|end_of_text|>"],
            },
        }

    async def generate(
        self,
        prompt: str,
        system_prompt: Optional[str] = None,
        temperature: float = 0.7,
        max_tokens: int = 2048,
        **kwargs,
    ) -> LLMResponse:
        if not self.is_available():
            raise RuntimeError(
                f"SageMaker provider not available. "
                f"endpoint='{self.endpoint_name}' client={self._client}"
            )

        start_time = time.time()
        payload = self._build_tgi_payload(prompt, system_prompt, temperature, max_tokens)

        def _invoke():
            return self._client.invoke_endpoint(
                EndpointName=self.endpoint_name,
                ContentType="application/json",
                Body=json.dumps(payload),
            )

        try:
            response = await asyncio.to_thread(_invoke)
        except Exception as e:
            logger.error(f"SageMaker invoke_endpoint failed: {e}")
            raise

        body = response["Body"].read().decode("utf-8")
        latency_ms = (time.time() - start_time) * 1000

        # TGI returns either a list of dicts or a single dict depending on the
        # inference handler. Handle both forms.
        parsed = json.loads(body)
        if isinstance(parsed, list) and parsed:
            text = parsed[0].get("generated_text", "")
        elif isinstance(parsed, dict):
            text = parsed.get("generated_text", "")
        else:
            text = ""

        # TGI doesn't return token counts by default — approximate using whitespace.
        # For exact counts, enable `details: True` in the request and parse.
        approx_prompt_tokens = len(prompt.split()) + (len(system_prompt.split()) if system_prompt else 0)
        approx_completion_tokens = len(text.split())

        logger.info(
            f"SageMaker generation complete | endpoint={self.endpoint_name} "
            f"~tokens={approx_prompt_tokens}+{approx_completion_tokens} "
            f"latency={latency_ms:.0f}ms"
        )

        return LLMResponse(
            text=text,
            model=self.model_label,
            prompt_tokens=approx_prompt_tokens,
            completion_tokens=approx_completion_tokens,
            total_tokens=approx_prompt_tokens + approx_completion_tokens,
            latency_ms=latency_ms,
            backend=SAGEMAKER_BACKEND,
        )


# ─────────────────────────────────────────────────────────────────────────────
# Wiring helper — called by the AWS-side entrypoint, not by gateway.py.
# ─────────────────────────────────────────────────────────────────────────────


def build_aws_gateway(**kwargs) -> LLMGateway:
    """
    Construct an LLMGateway pre-wired with the SageMaker provider.

    Call this from the FastAPI startup hook when running on AWS. It builds the
    normal LLMGateway (which auto-registers Gemini / vLLM if their env vars are
    set) and then attaches the SageMaker provider on top.

    Behavior:
      - If SAGEMAKER_ENDPOINT is set, SageMaker becomes the default backend.
      - Otherwise the gateway falls back to whatever LLM_BACKEND points at
        (typically 'openai' on AWS, or the GCP-style Gemini if a key is set).
    """
    gateway = LLMGateway(backend=kwargs.pop("backend", None), **kwargs)
    _attach_sagemaker(gateway)
    return gateway


def _attach_sagemaker(gateway: LLMGateway) -> None:
    """Register a SageMakerProvider on an existing gateway if the env is configured."""
    provider = SageMakerProvider()
    if provider.is_available():
        gateway.providers[SAGEMAKER_BACKEND] = provider
        if os.getenv("LLM_BACKEND", "").lower() == SAGEMAKER_BACKEND.value:
            gateway.backend = SAGEMAKER_BACKEND
        logger.info(
            "SageMaker provider attached to LLM gateway | "
            f"primary_backend={gateway.backend}"
        )
    else:
        logger.info(
            "SageMaker endpoint not configured (SAGEMAKER_ENDPOINT unset) — "
            "gateway will use other configured providers."
        )


def install() -> None:
    """
    Monkey-patch LLMGateway.__init__ so every gateway created in this process
    is auto-extended with the SageMaker provider.

    Why this exists: the existing GCP RAGPipeline constructs LLMGateway(...)
    directly and we don't want to modify that file. Importing this module
    early in the AWS entrypoint (before pipeline.py is imported) installs the
    extension transparently — GCP behaviour is unchanged because the patch is
    only applied when this module is imported, and SageMaker only activates
    when SAGEMAKER_ENDPOINT is set.

    Idempotent — safe to call multiple times.
    """
    if getattr(LLMGateway.__init__, "_sagemaker_patched", False):
        return

    _orig_init = LLMGateway.__init__

    def _patched_init(self, *args, **kwargs):
        _orig_init(self, *args, **kwargs)
        try:
            _attach_sagemaker(self)
        except Exception as exc:  # noqa: BLE001
            logger.warning(f"SageMaker auto-attach failed (non-fatal): {exc}")

    _patched_init._sagemaker_patched = True  # type: ignore[attr-defined]
    LLMGateway.__init__ = _patched_init  # type: ignore[method-assign]
    logger.info("SageMaker provider patch installed on LLMGateway")


__all__ = [
    "SageMakerProvider",
    "build_aws_gateway",
    "install",
    "SAGEMAKER_BACKEND",
]


# Auto-install when imported via `python -m src.llm.sagemaker_provider`
# or by the AWS Docker entrypoint (`-c "import ...sagemaker_provider"`).
if os.getenv("SAGEMAKER_AUTOINSTALL", "1") == "1":
    install()
