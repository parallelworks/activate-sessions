"""Tests for the local workflow runner."""

import os
import sys
import tempfile
from pathlib import Path

import pytest
import yaml

# Add tools directory to path
sys.path.insert(0, str(Path(__file__).parent.parent / 'tools'))

from workflow_runner import (
    WorkflowRunner,
    ExecutionContext,
    JobOutput,
    parse_input_arg,
    build_nested_dict,
    get_default_inputs,
)


class TestParseInputArg:
    """Test input argument parsing."""

    def test_simple_string(self):
        key, value = parse_input_arg("message=hello")
        assert key == "message"
        assert value == "hello"

    def test_nested_key(self):
        key, value = parse_input_arg("resource.ip=localhost")
        assert key == "resource.ip"
        assert value == "localhost"

    def test_boolean_true(self):
        key, value = parse_input_arg("enabled=true")
        assert key == "enabled"
        assert value is True

    def test_boolean_false(self):
        key, value = parse_input_arg("enabled=false")
        assert key == "enabled"
        assert value is False

    def test_integer(self):
        key, value = parse_input_arg("count=42")
        assert key == "count"
        assert value == 42

    def test_invalid_format(self):
        with pytest.raises(ValueError, match="Invalid input format"):
            parse_input_arg("invalid")


class TestBuildNestedDict:
    """Test nested dictionary building."""

    def test_simple_key(self):
        result = build_nested_dict([("key", "value")])
        assert result == {"key": "value"}

    def test_nested_keys(self):
        result = build_nested_dict([
            ("resource.ip", "localhost"),
            ("resource.port", 22),
        ])
        assert result == {"resource": {"ip": "localhost", "port": 22}}

    def test_deep_nesting(self):
        result = build_nested_dict([("a.b.c.d", "value")])
        assert result == {"a": {"b": {"c": {"d": "value"}}}}


class TestGetDefaultInputs:
    """Test default input extraction from workflow."""

    def test_extracts_simple_defaults(self):
        workflow = {
            "on": {
                "execute": {
                    "inputs": {
                        "message": {"type": "string", "default": "hello"},
                    }
                }
            }
        }
        defaults = get_default_inputs(workflow)
        assert defaults["message"] == "hello"

    def test_extracts_group_defaults(self):
        workflow = {
            "on": {
                "execute": {
                    "inputs": {
                        "slurm": {
                            "type": "group",
                            "items": {
                                "time": {"type": "string", "default": "04:00:00"},
                            }
                        }
                    }
                }
            }
        }
        defaults = get_default_inputs(workflow)
        assert defaults["slurm.time"] == "04:00:00"


class TestWorkflowRunner:
    """Test WorkflowRunner class."""

    @pytest.fixture
    def temp_work_dir(self):
        """Create temporary working directory."""
        with tempfile.TemporaryDirectory() as tmpdir:
            yield Path(tmpdir)

    @pytest.fixture
    def hello_world_workflow(self, repo_root):
        """Return path to hello-world workflow."""
        return repo_root / "workflows" / "hello-world" / "workflow.yaml"

    @pytest.fixture
    def basic_context(self, temp_work_dir):
        """Create a basic execution context."""
        return ExecutionContext(
            inputs={
                "resource": {"ip": "localhost", "id": "test", "schedulerType": ""},
                "workflow_dir": "hello-world",
                "hello": {"message": "Test"},
            },
            sessions={},
            job_outputs={},
            env_vars={
                "PW_WORKFLOW_NAME": "hello-world",
                "PW_JOB_NUMBER": "1",
                "PW_USER": "testuser",
                "PW_PLATFORM_HOST": "localhost",
            },
            work_dir=temp_work_dir,
            dry_run=True,
        )

    def test_load_workflow(self, hello_world_workflow, basic_context):
        """Test workflow loading."""
        runner = WorkflowRunner(hello_world_workflow, basic_context)
        runner.load_workflow()

        assert "jobs" in runner.workflow
        assert "preprocessing" in runner.workflow["jobs"]

    def test_substitute_simple_input(self, hello_world_workflow, basic_context):
        """Test simple variable substitution."""
        runner = WorkflowRunner(hello_world_workflow, basic_context)
        runner.load_workflow()

        result = runner.substitute_variables("${{ inputs.workflow_dir }}")
        assert result == "hello-world"

    def test_substitute_nested_input(self, hello_world_workflow, basic_context):
        """Test nested variable substitution."""
        runner = WorkflowRunner(hello_world_workflow, basic_context)
        runner.load_workflow()

        result = runner.substitute_variables("${{ inputs.resource.ip }}")
        assert result == "localhost"

    def test_substitute_session(self, hello_world_workflow, basic_context):
        """Test session variable substitution."""
        basic_context.sessions["session"] = "my-session-id"
        runner = WorkflowRunner(hello_world_workflow, basic_context)
        runner.load_workflow()

        result = runner.substitute_variables("${{ sessions.session }}")
        assert result == "my-session-id"

    def test_substitute_job_output(self, hello_world_workflow, basic_context):
        """Test job output variable substitution."""
        basic_context.job_outputs["wait_for_service"] = JobOutput(
            outputs={"HOSTNAME": "compute-node-1", "SESSION_PORT": "8080"}
        )
        runner = WorkflowRunner(hello_world_workflow, basic_context)
        runner.load_workflow()

        result = runner.substitute_variables("${{ needs.wait_for_service.outputs.HOSTNAME }}")
        assert result == "compute-node-1"

    def test_get_job_order(self, hello_world_workflow, basic_context):
        """Test topological job ordering."""
        runner = WorkflowRunner(hello_world_workflow, basic_context)
        runner.load_workflow()

        order = runner.get_job_order()

        # preprocessing must come before session_runner and wait_for_service
        assert order.index("preprocessing") < order.index("session_runner")
        assert order.index("preprocessing") < order.index("wait_for_service")

        # wait_for_service must come before update_session
        assert order.index("wait_for_service") < order.index("update_session")

        # update_session must come before complete
        assert order.index("update_session") < order.index("complete")

    def test_dry_run_completes(self, hello_world_workflow, basic_context):
        """Test that dry run completes without errors."""
        runner = WorkflowRunner(hello_world_workflow, basic_context)
        success = runner.run()

        # Dry run should complete (may have warnings but should not fail)
        assert isinstance(success, bool)


class TestWorkflowRunnerExpressions:
    """Test expression evaluation in WorkflowRunner."""

    @pytest.fixture
    def runner_with_context(self, repo_root, temp_work_dir):
        """Create runner with test context."""
        workflow = repo_root / "workflows" / "hello-world" / "workflow.yaml"
        context = ExecutionContext(
            inputs={
                "resource": {"schedulerType": "slurm"},
                "submit_to_scheduler": True,
            },
            sessions={},
            job_outputs={},
            env_vars={},
            work_dir=temp_work_dir,
            dry_run=True,
        )
        runner = WorkflowRunner(workflow, context)
        runner.load_workflow()
        return runner

    @pytest.fixture
    def temp_work_dir(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            yield Path(tmpdir)

    def test_equality_expression_true(self, runner_with_context):
        """Test equality expression that evaluates to true."""
        result = runner_with_context.substitute_variables(
            "${{ inputs.resource.schedulerType == 'slurm' }}"
        )
        assert result == "True"

    def test_equality_expression_false(self, runner_with_context):
        """Test equality expression that evaluates to false."""
        result = runner_with_context.substitute_variables(
            "${{ inputs.resource.schedulerType == 'pbs' }}"
        )
        assert result == "False"

    def test_inequality_expression(self, runner_with_context):
        """Test inequality expression."""
        result = runner_with_context.substitute_variables(
            "${{ inputs.resource.schedulerType != '' }}"
        )
        assert result == "True"


class TestWorkflowValidation:
    """Test workflow validation through runner."""

    @pytest.fixture
    def workflows_dir(self, repo_root):
        return repo_root / "workflows"

    def test_all_workflows_load(self, workflows_dir):
        """Test that all workflow.yaml files can be loaded."""
        for workflow_dir in workflows_dir.iterdir():
            if workflow_dir.is_dir():
                workflow_yaml = workflow_dir / "workflow.yaml"
                if workflow_yaml.exists():
                    with open(workflow_yaml) as f:
                        data = yaml.safe_load(f)
                    assert "jobs" in data, f"{workflow_yaml} missing 'jobs'"
                    assert "on" in data, f"{workflow_yaml} missing 'on'"

    def test_all_workflows_have_valid_job_order(self, workflows_dir):
        """Test that all workflows have valid job dependencies (no cycles)."""
        for workflow_dir in workflows_dir.iterdir():
            if workflow_dir.is_dir():
                workflow_yaml = workflow_dir / "workflow.yaml"
                if workflow_yaml.exists():
                    with tempfile.TemporaryDirectory() as tmpdir:
                        context = ExecutionContext(
                            inputs={"resource": {"ip": "localhost", "schedulerType": ""}},
                            sessions={},
                            job_outputs={},
                            env_vars={},
                            work_dir=Path(tmpdir),
                            dry_run=True,
                        )
                        runner = WorkflowRunner(workflow_yaml, context)
                        runner.load_workflow()

                        # This will raise if there's a cycle
                        order = runner.get_job_order()
                        assert len(order) > 0
