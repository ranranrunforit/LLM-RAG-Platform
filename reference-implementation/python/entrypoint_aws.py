"""
AWS container entrypoint.

Importing src.llm.sagemaker_provider triggers its auto-install hook (see the
bottom of that module), which monkey-patches LLMGateway.__init__ so every
gateway created in this process auto-attaches a SageMakerProvider when
SAGEMAKER_ENDPOINT is set. The GCP source files are unchanged.

Run via:  python entrypoint_aws.py
The matching CMD lives in Dockerfile.aws.
"""

import os
import sys


def main() -> None:
    # Ensure /app (containing the `src` package) is on sys.path so that
    # `import src.*` resolves both here and inside uvicorn workers.
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)

    # This import has the side-effect of installing the SageMaker patch
    # process-wide (see SAGEMAKER_AUTOINSTALL in sagemaker_provider.py).
    import src.llm.sagemaker_provider  # noqa: F401

    import uvicorn

    port = int(os.getenv("PORT", "8080"))
    uvicorn.run(
        "src.api.main:app",
        host="0.0.0.0",
        port=port,
        workers=1,
        log_level="info",
    )


if __name__ == "__main__":
    main()
