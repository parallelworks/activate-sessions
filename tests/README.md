# Tests

Pytest tests for validating interactive session workflows.

## Running Tests

```bash
# Run all tests
pytest

# Run with verbose output
pytest -v

# Run specific test file
pytest tests/test_workflow_yaml.py
pytest tests/test_start_script.py

# Run specific test
pytest tests/test_workflow_yaml.py::TestWorkflowYamlValid::test_is_valid_yaml
```

## Test Coverage

### `test_workflow_yaml.py`

Validates that `workflow.yaml` files:
- Are valid YAML
- Have required sections (`permissions`, `sessions`, `jobs`, `on.execute.inputs`)
- Have required jobs (`preprocessing`, `session_runner`, `wait_for_service`, `update_session`, `complete`)
- Use marketplace/job_runner/v4.0
- Have correct job dependencies
- Use parallelworks/checkout and parallelworks/update-session
- Reference job outputs correctly
- Don't use old pattern elements

### `test_start_script.py`

Validates that `start.sh` service scripts:
- Exist and are executable
- Create required coordination files (`HOSTNAME`, `SESSION_PORT`, `job.started`)
- Allocate a port dynamically
- Start a service
- Use platform environment variables
- Have proper shebang and error handling
- Don't reference old pattern elements

## Adding More Workflows

When adding a new workflow, add fixtures in `conftest.py` for the new workflow path:

```python
@pytest.fixture
def my_workflow_dir(workflows_dir: Path) -> Path:
    return workflows_dir / "my-service" / "general"
```

Then create a new test file or add tests that use these fixtures.
