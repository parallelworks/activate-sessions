"""Pytest configuration and fixtures for interactive session workflow tests."""

from pathlib import Path

import pytest


@pytest.fixture
def repo_root() -> Path:
    """Return the repository root directory."""
    return Path(__file__).parent.parent


@pytest.fixture
def workflows_dir(repo_root: Path) -> Path:
    """Return the workflows directory."""
    return repo_root / "workflows"


@pytest.fixture
def hello_world_dir(workflows_dir: Path) -> Path:
    """Return the hello-world workflow directory."""
    return workflows_dir / "hello-world"


@pytest.fixture
def workflow_yaml(hello_world_dir: Path) -> Path:
    """Return the hello-world workflow.yaml path."""
    return hello_world_dir / "workflow.yaml"


@pytest.fixture
def start_script(hello_world_dir: Path) -> Path:
    """Return the hello-world start.sh path."""
    return hello_world_dir / "start.sh"


@pytest.fixture
def workflow_content(workflow_yaml: Path) -> str:
    """Return the workflow.yaml file content."""
    return workflow_yaml.read_text()


@pytest.fixture
def start_script_content(start_script: Path) -> str:
    """Return the start.sh file content."""
    return start_script.read_text()
