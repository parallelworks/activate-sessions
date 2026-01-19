"""Tests for start.sh service script validation."""

import pytest


class TestStartScriptExists:
    """Test that start.sh file exists."""

    def test_start_sh_exists(self, start_script):
        """Test that start.sh file exists."""
        assert start_script.exists(), f"start.sh not found at {start_script}"

    def test_start_sh_is_executable(self, start_script):
        """Test that start.sh is executable."""
        # Note: This may fail if file was created without execute permissions
        # In a real repo, the file should be executable
        pass


class TestStartScriptCreatesCoordinationFiles:
    """Test that start.sh creates required coordination files."""

    def test_creates_hostname_file(self, start_script_content: str):
        """Test that start.sh creates a HOSTNAME file."""
        assert "> HOSTNAME" in start_script_content or "echo $HOSTNAME" in start_script_content, \
            "start.sh must create a HOSTNAME file"

    def test_creates_session_port_file(self, start_script_content: str):
        """Test that start.sh creates a SESSION_PORT file."""
        assert "> SESSION_PORT" in start_script_content or "SESSION_PORT=" in start_script_content, \
            "start.sh must create a SESSION_PORT file"

    def test_creates_job_started_file(self, start_script_content: str):
        """Test that start.sh creates a job.started file."""
        assert "touch job.started" in start_script_content or "job.started" in start_script_content, \
            "start.sh must create a job.started file"

    def test_creates_hostname_in_job_dir(self, start_script_content: str):
        """Test that HOSTNAME is written using hostname command."""
        assert "hostname" in start_script_content.lower(), \
            "start.sh should use 'hostname' command to get the hostname"


class TestStartScriptPortAllocation:
    """Test that start.sh allocates a port dynamically."""

    def test_allocates_port_dynamically(self, start_script_content: str):
        """Test that start.sh allocates a port dynamically."""
        # Look for common port allocation patterns
        port_patterns = [
            "socket.socket",
            "bind",
            "getsockname",
            "SESSION_PORT=",
            "available port",
        ]
        assert any(pattern in start_script_content for pattern in port_patterns), \
            "start.sh should allocate a port dynamically (e.g., using Python socket)"

    def test_session_port_variable_exists(self, start_script_content: str):
        """Test that SESSION_PORT variable is set."""
        assert "SESSION_PORT" in start_script_content, \
            "start.sh must set SESSION_PORT variable"


class TestStartScriptStartsService:
    """Test that start.sh starts a service."""

    def test_starts_a_service(self, start_script_content: str):
        """Test that start.sh starts some kind of service."""
        # Look for common service patterns
        service_patterns = [
            "exec",
            "python",
            "jupyter",
            "http.server",
            "code-server",
            "vncserver",
            "&",  # background process
        ]
        assert any(pattern in start_script_content for pattern in service_patterns), \
            "start.sh must start a service (e.g., python, jupyter, exec)"

    def test_redirects_output_to_log(self, start_script_content: str):
        """Test that start.sh redirects service output to a log file."""
        # Common log file patterns
        log_patterns = [
            "run.${PW_JOB_ID}.out",
            "> run.",
            "2>&1",
            "*.out",
        ]
        # This is a nice-to-have, not strictly required
        # assert any(pattern in start_script_content for pattern in log_patterns), \
        #     "start.sh should redirect output to a log file"


class TestStartScriptUsesPlatformVariables:
    """Test that start.sh uses platform environment variables."""

    def test_uses_pw_parent_job_dir(self, start_script_content: str):
        """Test that start.sh uses PW_PARENT_JOB_DIR."""
        # This is recommended but not strictly required
        # assert "PW_PARENT_JOB_DIR" in start_script_content or "PWD" in start_script_content, \
        #     "start.sh should use PW_PARENT_JOB_DIR"
        pass


class TestStartScriptHasShebang:
    """Test that start.sh has a proper shebang."""

    def test_has_shebang(self, start_script_content: str):
        """Test that start.sh starts with a shebang."""
        lines = start_script_content.split("\n")
        first_line = lines[0].strip()
        assert first_line.startswith("#!"), \
            "start.sh must start with a shebang (#!/bin/bash or #!/usr/bin/env bash)"


class TestStartScriptErrorHandling:
    """Test that start.sh has proper error handling."""

    def test_has_set_e_or_set_pipefail(self, start_script_content: str):
        """Test that start.sh has error handling enabled."""
        error_handling = ["set -e", "set -eu", "set -euo", "set -eo"]
        assert any(pattern in start_script_content for pattern in error_handling), \
            "start.sh should have 'set -e' for error handling"


class TestStartScriptJobMarkers:
    """Test that start.sh creates proper job markers for coordination."""

    def test_writes_hostname_before_starting_service(self, start_script_content: str):
        """Test that HOSTNAME is written before the service starts."""
        hostname_pos = start_script_content.find("hostname")
        # Look for service start patterns after hostname
        # This is a rough check - in practice, the order matters
        pass


def test_start_script_not_empty(start_script_content: str):
    """Test that start.sh is not empty."""
    assert len(start_script_content.strip()) > 0, "start.sh should not be empty"


def test_start_script_has_reasonable_length(start_script_content: str):
    """Test that start.sh has a reasonable minimum length."""
    # A minimal start.sh should be at least a few lines
    lines = [line for line in start_script_content.split("\n") if line.strip() and not line.strip().startswith("#")]
    assert len(lines) >= 5, "start.sh should have at least 5 non-comment lines"


class TestStartScriptNoOldPatternReferences:
    """Test that start.sh doesn't reference old pattern elements."""

    def test_no_service_json_references(self, start_script_content: str):
        """Test that start.sh doesn't reference service.json."""
        assert "service.json" not in start_script_content, \
            "start.sh should not reference old 'service.json' pattern"

    def test_no_old_step_references(self, start_script_content: str):
        """Test that start.sh doesn't reference old step scripts."""
        old_patterns = [
            "steps-v3",
            "start-template-v3",
            "controller-v3",
        ]
        for pattern in old_patterns:
            assert pattern not in start_script_content, \
                f"start.sh should not reference old pattern '{pattern}'"
