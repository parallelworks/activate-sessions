"""Tests for workflow YAML validation."""

import re
from pathlib import Path

import pytest
import yaml
from yaml import YAMLError


class TestWorkflowYamlValid:
    """Test that workflow.yaml is valid YAML and has required structure."""

    def test_is_valid_yaml(self, workflow_content: str):
        """Test that workflow.yaml is valid YAML."""
        try:
            yaml.safe_load(workflow_content)
        except YAMLError as e:
            pytest.fail(f"workflow.yaml is not valid YAML: {e}")

    def test_has_permissions_section(self, workflow_content: str):
        """Test that workflow.yaml has a permissions section."""
        data = yaml.safe_load(workflow_content)
        assert "permissions" in data, "workflow.yaml must have 'permissions' section"

    def test_has_sessions_section(self, workflow_content: str):
        """Test that workflow.yaml has a sessions section."""
        data = yaml.safe_load(workflow_content)
        assert "sessions" in data, "workflow.yaml must have 'sessions' section"

    def test_has_jobs_section(self, workflow_content: str):
        """Test that workflow.yaml has a jobs section."""
        data = yaml.safe_load(workflow_content)
        assert "jobs" in data, "workflow.yaml must have 'jobs' section"

    def test_has_execute_inputs_section(self, workflow_content: str):
        """Test that workflow.yaml has an on.execute.inputs section."""
        data = yaml.safe_load(workflow_content)
        assert "on" in data, "workflow.yaml must have 'on' section"
        assert "execute" in data["on"], "workflow.yaml must have 'on.execute' section"
        assert "inputs" in data["on"]["execute"], "workflow.yaml must have 'on.execute.inputs' section"


class TestWorkflowJobs:
    """Test that workflow.yaml has the required jobs."""

    def test_has_preprocessing_job(self, workflow_content: str):
        """Test that workflow.yaml has a preprocessing job."""
        data = yaml.safe_load(workflow_content)
        assert "preprocessing" in data.get("jobs", {}), "workflow.yaml must have 'preprocessing' job"

    def test_has_session_runner_job(self, workflow_content: str):
        """Test that workflow.yaml has a session_runner job."""
        data = yaml.safe_load(workflow_content)
        assert "session_runner" in data.get("jobs", {}), "workflow.yaml must have 'session_runner' job"

    def test_has_wait_for_service_job(self, workflow_content: str):
        """Test that workflow.yaml has a wait_for_service job."""
        data = yaml.safe_load(workflow_content)
        assert "wait_for_service" in data.get("jobs", {}), "workflow.yaml must have 'wait_for_service' job"

    def test_has_update_session_job(self, workflow_content: str):
        """Test that workflow.yaml has an update_session job."""
        data = yaml.safe_load(workflow_content)
        assert "update_session" in data.get("jobs", {}), "workflow.yaml must have 'update_session' job"

    def test_has_complete_job(self, workflow_content: str):
        """Test that workflow.yaml has a complete job."""
        data = yaml.safe_load(workflow_content)
        assert "complete" in data.get("jobs", {}), "workflow.yaml must have 'complete' job"


class TestWorkflowUsesMarketplaceJobRunner:
    """Test that workflow uses marketplace/job_runner/v4.0."""

    def test_uses_marketplace_job_runner(self, workflow_content: str):
        """Test that workflow.yaml uses marketplace/job_runner/v4.0."""
        assert "marketplace/job_runner" in workflow_content, \
            "workflow.yaml should use 'marketplace/job_runner'"


class TestWorkflowInputs:
    """Test that workflow.yaml has required inputs."""

    def test_has_resource_input(self, workflow_content: str):
        """Test that workflow.yaml has a resource input."""
        data = yaml.safe_load(workflow_content)
        inputs = data.get("on", {}).get("execute", {}).get("inputs", {})
        assert "resource" in inputs, "workflow.yaml must have 'resource' input"
        assert inputs["resource"].get("type") == "compute-clusters", \
            "resource input must be type 'compute-clusters'"

    def test_has_workflow_dir_input(self, workflow_content: str):
        """Test that workflow.yaml has a workflow_dir input."""
        data = yaml.safe_load(workflow_content)
        inputs = data.get("on", {}).get("execute", {}).get("inputs", {})
        assert "workflow_dir" in inputs, "workflow.yaml must have 'workflow_dir' input"


class TestWorkflowJobDependencies:
    """Test that workflow job dependencies are correct."""

    def test_session_runner_depends_on_preprocessing(self, workflow_content: str):
        """Test that session_runner depends on preprocessing."""
        data = yaml.safe_load(workflow_content)
        session_runner = data.get("jobs", {}).get("session_runner", {})
        needs = session_runner.get("needs", [])
        assert "preprocessing" in needs, "session_runner must depend on preprocessing"

    def test_wait_for_service_depends_on_preprocessing(self, workflow_content: str):
        """Test that wait_for_service depends on preprocessing."""
        data = yaml.safe_load(workflow_content)
        wait_for_service = data.get("jobs", {}).get("wait_for_service", {})
        needs = wait_for_service.get("needs", [])
        assert "preprocessing" in needs, "wait_for_service must depend on preprocessing"

    def test_update_session_depends_on_wait_for_service(self, workflow_content: str):
        """Test that update_session depends on wait_for_service."""
        data = yaml.safe_load(workflow_content)
        update_session = data.get("jobs", {}).get("update_session", {})
        needs = update_session.get("needs", [])
        assert "wait_for_service" in needs, "update_session must depend on wait_for_service"

    def test_complete_depends_on_update_session(self, workflow_content: str):
        """Test that complete depends on update_session."""
        data = yaml.safe_load(workflow_content)
        complete = data.get("jobs", {}).get("complete", {})
        needs = complete.get("needs", [])
        assert "update_session" in needs, "complete must depend on update_session"


class TestWorkflowUsesCheckout:
    """Test that workflow checks out service scripts."""

    def test_preprocessing_uses_checkout(self, workflow_content: str):
        """Test that preprocessing job uses parallelworks/checkout."""
        data = yaml.safe_load(workflow_content)
        preprocessing = data.get("jobs", {}).get("preprocessing", {})
        steps = preprocessing.get("steps", [])
        checkout_found = False
        for step in steps:
            uses = step.get("uses", "")
            if "parallelworks/checkout" in uses:
                checkout_found = True
                break
        assert checkout_found, "preprocessing job must use 'parallelworks/checkout'"


class TestWorkflowSparseCheckout:
    """Test that workflow sparse checkout includes utils/wait_service.sh."""

    def test_sparse_checkout_includes_wait_service(self, workflow_content: str):
        """Test that sparse_checkout includes utils/wait_service.sh."""
        assert "utils/wait_service.sh" in workflow_content, \
            "sparse_checkout must include 'utils/wait_service.sh'"


class TestWorkflowUsesUpdateSession:
    """Test that workflow uses parallelworks/update-session."""

    def test_update_session_job_uses_update_session(self, workflow_content: str):
        """Test that update_session job uses parallelworks/update-session."""
        data = yaml.safe_load(workflow_content)
        update_session = data.get("jobs", {}).get("update_session", {})
        steps = update_session.get("steps", [])
        update_session_found = False
        for step in steps:
            uses = step.get("uses", "")
            if "parallelworks/update-session" in uses:
                update_session_found = True
                break
        assert update_session_found, "update_session job must use 'parallelworks/update-session'"


class TestWorkflowReferencesOutputs:
    """Test that workflow correctly references job outputs."""

    def test_wait_for_service_outputs_hostname(self, workflow_content: str):
        """Test that workflow references wait_for_service.outputs.HOSTNAME."""
        assert "needs.wait_for_service.outputs.HOSTNAME" in workflow_content, \
            "workflow must reference 'needs.wait_for_service.outputs.HOSTNAME'"

    def test_wait_for_service_outputs_session_port(self, workflow_content: str):
        """Test that workflow references wait_for_service.outputs.SESSION_PORT."""
        assert "needs.wait_for_service.outputs.SESSION_PORT" in workflow_content, \
            "workflow must reference 'needs.wait_for_service.outputs.SESSION_PORT'"

    def test_update_session_outputs_local_port(self, workflow_content: str):
        """Test that workflow references update_session.outputs.local_port."""
        assert "needs.update_session.outputs.local_port" in workflow_content, \
            "workflow must reference 'needs.update_session.outputs.local_port'"


class TestWorkflowNoOldPatternReferences:
    """Test that workflow doesn't reference old pattern elements."""

    def test_no_steps_v3_references(self, workflow_content: str):
        """Test that workflow.yaml doesn't reference utils/steps-v3."""
        assert "steps-v3" not in workflow_content, \
            "workflow.yaml should not reference old 'utils/steps-v3' pattern"

    def test_no_old_utility_modules(self, workflow_content: str):
        """Test that workflow.yaml doesn't use old utility modules."""
        old_modules = [
            "utility_wait_target_hostname",
            "utility_wait_service_port",
            "utility_wait_ready",
            "utility_inputs",
            "utility_compute_session",
        ]
        for module in old_modules:
            assert module not in workflow_content, \
                f"workflow.yaml should not use old utility module '{module}'"


class TestWorkflowWaitServiceSourcesScript:
    """Test that wait_for_service sources the wait_service.sh script."""

    def test_wait_for_service_sources_wait_service_sh(self, workflow_content: str):
        """Test that wait_for_service sources utils/wait_service.sh."""
        assert "source utils/wait_service.sh" in workflow_content, \
            "wait_for_service job must source 'utils/wait_service.sh'"


def test_workflow_yaml_exists(workflow_yaml: Path):
    """Test that workflow.yaml file exists."""
    assert workflow_yaml.exists(), f"workflow.yaml not found at {workflow_yaml}"
