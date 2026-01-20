#!/usr/bin/env python3
"""
Local Workflow Runner for Activate Session Workflows

Simulates workflow execution locally for testing without pushing to the platform.
Supports variable substitution, job dependencies, shell execution, and action stubs.

Usage:
    python tools/workflow_runner.py workflows/hello-world/workflow.yaml
    python tools/workflow_runner.py workflows/hello-world/workflow.yaml --dry-run
    python tools/workflow_runner.py workflows/hello-world/workflow.yaml -i resource.ip=localhost
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import shutil
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml


@dataclass
class JobOutput:
    """Outputs from a completed job."""
    outputs: dict[str, str] = field(default_factory=dict)
    success: bool = True
    error: str | None = None


@dataclass
class ExecutionContext:
    """Context for workflow execution."""
    inputs: dict[str, Any]
    sessions: dict[str, str]
    job_outputs: dict[str, JobOutput]
    env_vars: dict[str, str]
    work_dir: Path
    dry_run: bool = False
    verbose: bool = False
    skip_ssh: bool = True  # Always skip SSH for local execution


class WorkflowRunner:
    """Runs Activate workflows locally for testing."""

    def __init__(self, workflow_path: Path, context: ExecutionContext):
        self.workflow_path = workflow_path
        self.workflow_dir = workflow_path.parent
        self.context = context
        self.workflow: dict[str, Any] = {}

    def load_workflow(self) -> None:
        """Load and parse the workflow YAML file."""
        with open(self.workflow_path) as f:
            self.workflow = yaml.safe_load(f)

    def substitute_variables(self, value: Any, extra_context: dict[str, Any] | None = None) -> Any:
        """
        Recursively substitute ${{ ... }} variables in a value.

        Supports:
        - ${{ inputs.X }} - Input values
        - ${{ inputs.X.Y }} - Nested input values
        - ${{ sessions.X }} - Session names
        - ${{ needs.job.outputs.X }} - Job outputs
        - ${{ env.X }} - Environment variables
        - Simple expressions like: X != '' or X == 'value'
        """
        if isinstance(value, str):
            return self._substitute_string(value, extra_context)
        elif isinstance(value, dict):
            return {k: self.substitute_variables(v, extra_context) for k, v in value.items()}
        elif isinstance(value, list):
            return [self.substitute_variables(item, extra_context) for item in value]
        return value

    def _substitute_string(self, text: str, extra_context: dict[str, Any] | None = None) -> str:
        """Substitute variables in a string."""
        pattern = r'\$\{\{\s*(.+?)\s*\}\}'

        def replacer(match: re.Match) -> str:
            expr = match.group(1).strip()
            return str(self._evaluate_expression(expr, extra_context))

        return re.sub(pattern, replacer, text)

    def _evaluate_expression(self, expr: str, extra_context: dict[str, Any] | None = None) -> Any:
        """Evaluate a template expression."""
        extra = extra_context or {}

        # Handle comparison expressions
        if ' != ' in expr:
            left, right = expr.split(' != ', 1)
            left_val = self._evaluate_expression(left.strip(), extra)
            right_val = self._parse_literal(right.strip())
            return left_val != right_val

        if ' == ' in expr:
            left, right = expr.split(' == ', 1)
            left_val = self._evaluate_expression(left.strip(), extra)
            right_val = self._parse_literal(right.strip())
            return left_val == right_val

        if ' || ' in expr:
            parts = expr.split(' || ')
            return any(self._evaluate_expression(p.strip(), extra) for p in parts)

        if ' && ' in expr:
            parts = expr.split(' && ')
            return all(self._evaluate_expression(p.strip(), extra) for p in parts)

        # Handle property access
        if expr.startswith('inputs.'):
            return self._get_nested_value(self.context.inputs, expr[7:])

        if expr.startswith('sessions.'):
            session_name = expr[9:]
            return self.context.sessions.get(session_name, f"session-{session_name}")

        if expr.startswith('needs.'):
            # needs.job_name.outputs.output_name
            parts = expr[6:].split('.')
            if len(parts) >= 3 and parts[1] == 'outputs':
                job_name = parts[0]
                output_name = '.'.join(parts[2:])
                job_output = self.context.job_outputs.get(job_name)
                if job_output:
                    return job_output.outputs.get(output_name, '')
            return ''

        if expr.startswith('env.'):
            env_name = expr[4:]
            return self.context.env_vars.get(env_name, os.environ.get(env_name, ''))

        # Check extra context (for step-level variables)
        if expr in extra:
            return extra[expr]

        # Return expression as-is if not recognized
        return expr

    def _get_nested_value(self, obj: dict, path: str) -> Any:
        """Get a nested value from a dict using dot notation."""
        parts = path.split('.')
        current = obj
        for part in parts:
            if isinstance(current, dict):
                current = current.get(part, '')
            else:
                return ''
        return current

    def _parse_literal(self, value: str) -> Any:
        """Parse a literal value from an expression."""
        # Remove quotes
        if (value.startswith("'") and value.endswith("'")) or \
           (value.startswith('"') and value.endswith('"')):
            return value[1:-1]
        if value == 'true':
            return True
        if value == 'false':
            return False
        if value == '':
            return ''
        try:
            return int(value)
        except ValueError:
            pass
        return value

    def get_job_order(self) -> list[str]:
        """Return jobs in topologically sorted order based on dependencies."""
        jobs = self.workflow.get('jobs', {})

        # Build dependency graph
        dependencies: dict[str, set[str]] = {}
        for job_name, job_config in jobs.items():
            needs = job_config.get('needs', [])
            if isinstance(needs, str):
                needs = [needs]
            dependencies[job_name] = set(needs)

        # Topological sort (Kahn's algorithm)
        result: list[str] = []
        no_deps = [j for j, deps in dependencies.items() if not deps]

        while no_deps:
            job = no_deps.pop(0)
            result.append(job)

            for other_job, deps in dependencies.items():
                if job in deps:
                    deps.remove(job)
                    if not deps and other_job not in result:
                        no_deps.append(other_job)

        if len(result) != len(jobs):
            remaining = set(jobs.keys()) - set(result)
            raise ValueError(f"Circular dependency detected in jobs: {remaining}")

        return result

    def run_job(self, job_name: str, job_config: dict) -> JobOutput:
        """Execute a single job."""
        print(f"\n{'='*60}")
        print(f"JOB: {job_name}")
        print(f"{'='*60}")

        output = JobOutput()
        steps = job_config.get('steps', [])

        for i, step in enumerate(steps):
            step_name = step.get('name', f'Step {i+1}')
            print(f"\n  [{i+1}/{len(steps)}] {step_name}")

            try:
                step_output = self.run_step(step, job_name)
                output.outputs.update(step_output)
            except Exception as e:
                output.success = False
                output.error = str(e)
                print(f"    ERROR: {e}")
                if not self.context.dry_run:
                    break

        return output

    def run_step(self, step: dict, job_name: str) -> dict[str, str]:
        """Execute a single step and return its outputs."""
        outputs: dict[str, str] = {}

        # Handle 'uses' action
        if 'uses' in step:
            action = step['uses']
            action_with = self.substitute_variables(step.get('with', {}))
            outputs = self.run_action(action, action_with, step)

        # Handle 'run' command
        if 'run' in step:
            run_cmd = self.substitute_variables(step['run'])
            outputs = self.run_shell_command(run_cmd, step)

        return outputs

    def run_action(self, action: str, params: dict, step: dict) -> dict[str, str]:
        """Run a workflow action (with stubs for platform actions)."""
        print(f"    Action: {action}")

        if self.context.verbose:
            print(f"    Params: {params}")

        if self.context.dry_run:
            print(f"    [DRY-RUN] Would execute action: {action}")
            return self._stub_action_outputs(action, params)

        # Stub implementations for platform-specific actions
        if 'parallelworks/checkout' in action:
            return self._action_checkout(params)

        if 'marketplace/job_runner' in action:
            return self._action_job_runner(params)

        if 'parallelworks/update-session' in action:
            return self._action_update_session(params)

        print(f"    [STUB] Unknown action: {action}")
        return self._stub_action_outputs(action, params)

    def _action_checkout(self, params: dict) -> dict[str, str]:
        """Stub for parallelworks/checkout - copies local workflow files."""
        print("    [LOCAL] Simulating checkout by using local files")

        # In local mode, files are already present
        repo_root = self.workflow_path.parent.parent.parent

        sparse_checkout = params.get('sparse_checkout', [])
        for path in sparse_checkout:
            src = repo_root / path.replace('${{ inputs.workflow_dir }}',
                                          self.context.inputs.get('workflow_dir', 'hello-world'))
            print(f"    Checkout path: {src}")

        return {}

    def _action_job_runner(self, params: dict) -> dict[str, str]:
        """Stub for marketplace/job_runner - runs script locally."""
        print("    [LOCAL] Running script locally (no scheduler)")

        script_path = params.get('script_path', '')
        # Resolve environment variables in script path
        script_path = script_path.replace('${PW_PARENT_JOB_DIR}', str(self.context.work_dir))
        script_path = self.substitute_variables(script_path)

        # Convert to Path and resolve
        script = Path(script_path)
        if not script.is_absolute():
            script = self.context.work_dir / script

        # For local testing, look in the workflow directory
        if not script.exists():
            local_script = self.workflow_dir / script.name
            if local_script.exists():
                script = local_script

        if script.exists():
            print(f"    Script: {script}")

            # Create a mock inputs.sh if we have inputs
            self._create_inputs_sh()

            # Run the script
            result = subprocess.run(
                ['bash', str(script)],
                cwd=self.context.work_dir,
                env={**os.environ, **self.context.env_vars},
                capture_output=True,
                text=True,
                timeout=300
            )

            if self.context.verbose or result.returncode != 0:
                if result.stdout:
                    print(f"    STDOUT:\n{self._indent(result.stdout)}")
                if result.stderr:
                    print(f"    STDERR:\n{self._indent(result.stderr)}")

            if result.returncode != 0:
                raise RuntimeError(f"Script failed with exit code {result.returncode}")

            # Read coordination files if they exist
            outputs = {}
            for coord_file in ['HOSTNAME', 'SESSION_PORT']:
                coord_path = self.context.work_dir / coord_file
                if coord_path.exists():
                    outputs[coord_file] = coord_path.read_text().strip()
                    print(f"    Output {coord_file}: {outputs[coord_file]}")

            return outputs
        else:
            print(f"    [WARN] Script not found: {script}")
            return {}

    def _action_update_session(self, params: dict) -> dict[str, str]:
        """Stub for parallelworks/update-session."""
        print("    [STUB] update-session - session proxy not available locally")
        print(f"    Would configure session:")
        print(f"      - target: {params.get('target', 'N/A')}")
        print(f"      - name: {params.get('name', 'N/A')}")
        print(f"      - remoteHost: {params.get('remoteHost', 'N/A')}")
        print(f"      - remotePort: {params.get('remotePort', 'N/A')}")
        return {}

    def _stub_action_outputs(self, action: str, params: dict) -> dict[str, str]:
        """Return stub outputs for unknown actions."""
        return {}

    def run_shell_command(self, command: str, step: dict) -> dict[str, str]:
        """Execute a shell command."""
        # Skip SSH wrapper for local execution
        ssh_config = step.get('ssh', {})
        if ssh_config and self.context.skip_ssh:
            print(f"    [LOCAL] Skipping SSH to {ssh_config.get('remoteHost', 'unknown')}")

        print(f"    Command:\n{self._indent(command)}")

        if self.context.dry_run:
            print("    [DRY-RUN] Would execute command")
            return {}

        # Create outputs file for the command to write to
        outputs_file = self.context.work_dir / 'step_outputs.txt'

        env = {
            **os.environ,
            **self.context.env_vars,
            'OUTPUTS': str(outputs_file),
            'PW_PARENT_JOB_DIR': str(self.context.work_dir),
        }

        result = subprocess.run(
            ['bash', '-c', command],
            cwd=self.context.work_dir,
            env=env,
            capture_output=True,
            text=True,
            timeout=300
        )

        if self.context.verbose or result.returncode != 0:
            if result.stdout:
                print(f"    STDOUT:\n{self._indent(result.stdout)}")
            if result.stderr:
                print(f"    STDERR:\n{self._indent(result.stderr)}")

        if result.returncode != 0:
            raise RuntimeError(f"Command failed with exit code {result.returncode}")

        # Parse outputs from OUTPUTS file
        outputs = {}
        if outputs_file.exists():
            for line in outputs_file.read_text().splitlines():
                if '=' in line:
                    key, value = line.split('=', 1)
                    outputs[key.strip()] = value.strip()

        # Also check for coordination files
        for coord_file in ['HOSTNAME', 'SESSION_PORT', 'slug']:
            coord_path = self.context.work_dir / coord_file
            if coord_path.exists():
                outputs[coord_file] = coord_path.read_text().strip()

        return outputs

    def _create_inputs_sh(self) -> None:
        """Create an inputs.sh file with exported variables."""
        inputs_sh = self.context.work_dir / 'inputs.sh'
        lines = ['#!/bin/bash', '# Auto-generated inputs for local testing']

        def flatten_inputs(prefix: str, obj: Any) -> None:
            if isinstance(obj, dict):
                for key, value in obj.items():
                    new_prefix = f"{prefix}_{key}" if prefix else key
                    flatten_inputs(new_prefix, value)
            else:
                # Convert to shell-safe value
                if isinstance(obj, bool):
                    val = 'true' if obj else 'false'
                elif obj is None:
                    val = ''
                else:
                    val = str(obj)
                lines.append(f'export {prefix}="{val}"')

        flatten_inputs('', self.context.inputs)
        inputs_sh.write_text('\n'.join(lines) + '\n')

    def _indent(self, text: str, spaces: int = 6) -> str:
        """Indent text for display."""
        prefix = ' ' * spaces
        return '\n'.join(prefix + line for line in text.splitlines())

    def run(self) -> bool:
        """Execute the workflow and return success status."""
        self.load_workflow()

        print(f"\nWorkflow: {self.workflow_path}")
        print(f"Work Dir: {self.context.work_dir}")
        print(f"Mode: {'DRY-RUN' if self.context.dry_run else 'EXECUTE'}")

        # Initialize sessions
        sessions = self.workflow.get('sessions', {})
        for session_name in sessions:
            if session_name not in self.context.sessions:
                self.context.sessions[session_name] = f"local-session-{session_name}"

        print(f"\nSessions: {self.context.sessions}")
        print(f"Inputs: {self.context.inputs}")

        # Get job execution order
        job_order = self.get_job_order()
        print(f"\nJob execution order: {' -> '.join(job_order)}")

        # Execute jobs
        all_success = True
        for job_name in job_order:
            job_config = self.workflow['jobs'][job_name]

            # Check if dependencies succeeded
            needs = job_config.get('needs', [])
            if isinstance(needs, str):
                needs = [needs]

            deps_ok = all(
                self.context.job_outputs.get(dep, JobOutput()).success
                for dep in needs
            )

            if not deps_ok:
                print(f"\n[SKIP] Job {job_name} - dependency failed")
                self.context.job_outputs[job_name] = JobOutput(success=False, error="Dependency failed")
                all_success = False
                continue

            output = self.run_job(job_name, job_config)
            self.context.job_outputs[job_name] = output

            if not output.success:
                all_success = False
                if not self.context.dry_run:
                    print(f"\n[FAIL] Job {job_name} failed: {output.error}")
                    # Continue to show what would happen in subsequent jobs

        # Summary
        print(f"\n{'='*60}")
        print("EXECUTION SUMMARY")
        print(f"{'='*60}")
        for job_name, output in self.context.job_outputs.items():
            status = "PASS" if output.success else "FAIL"
            print(f"  {job_name}: {status}")
            if output.outputs:
                for k, v in output.outputs.items():
                    print(f"    -> {k}: {v}")

        return all_success


def parse_input_arg(arg: str) -> tuple[str, Any]:
    """Parse an input argument like 'resource.ip=localhost'."""
    if '=' not in arg:
        raise ValueError(f"Invalid input format: {arg} (expected key=value)")
    key, value = arg.split('=', 1)

    # Parse value type
    if value.lower() == 'true':
        value = True
    elif value.lower() == 'false':
        value = False
    elif value.isdigit():
        value = int(value)

    return key, value


def build_nested_dict(flat_inputs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Build a nested dict from flat key=value pairs."""
    result: dict[str, Any] = {}
    for key, value in flat_inputs:
        parts = key.split('.')
        current = result
        for part in parts[:-1]:
            if part not in current:
                current[part] = {}
            current = current[part]
        current[parts[-1]] = value
    return result


def get_default_inputs(workflow: dict) -> dict[str, Any]:
    """Extract default input values from workflow definition."""
    defaults: dict[str, Any] = {}
    inputs_def = workflow.get('on', {}).get('execute', {}).get('inputs', {})

    def extract_defaults(prefix: str, obj: dict) -> None:
        for key, config in obj.items():
            full_key = f"{prefix}.{key}" if prefix else key

            if isinstance(config, dict):
                if 'default' in config:
                    defaults[full_key] = config['default']
                if config.get('type') == 'group' and 'items' in config:
                    extract_defaults(full_key, config['items'])

    extract_defaults('', inputs_def)
    return defaults


def main() -> int:
    parser = argparse.ArgumentParser(
        description='Run Activate workflows locally for testing',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  # Dry-run hello-world workflow
  python tools/workflow_runner.py workflows/hello-world/workflow.yaml --dry-run

  # Run with custom inputs
  python tools/workflow_runner.py workflows/hello-world/workflow.yaml \\
    -i resource.ip=localhost \\
    -i hello.message="Test Message"

  # Verbose output
  python tools/workflow_runner.py workflows/hello-world/workflow.yaml -v
'''
    )

    parser.add_argument('workflow', type=Path, help='Path to workflow.yaml')
    parser.add_argument('-i', '--input', action='append', dest='inputs', default=[],
                        help='Input value (e.g., resource.ip=localhost)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would be executed without running')
    parser.add_argument('-v', '--verbose', action='store_true',
                        help='Verbose output')
    parser.add_argument('--work-dir', type=Path,
                        help='Working directory (default: temp dir)')
    parser.add_argument('--keep-work-dir', action='store_true',
                        help='Keep working directory after execution')

    args = parser.parse_args()

    if not args.workflow.exists():
        print(f"Error: Workflow not found: {args.workflow}", file=sys.stderr)
        return 1

    # Load workflow to get defaults
    with open(args.workflow) as f:
        workflow = yaml.safe_load(f)

    # Build inputs from defaults + command line
    default_inputs = get_default_inputs(workflow)
    cli_inputs = [parse_input_arg(inp) for inp in args.inputs]

    # Merge defaults with CLI inputs
    all_inputs = build_nested_dict(
        [(k, v) for k, v in default_inputs.items()] +
        cli_inputs
    )

    # Add required mock values for resource if not provided
    if 'resource' not in all_inputs:
        all_inputs['resource'] = {}
    if 'ip' not in all_inputs['resource']:
        all_inputs['resource']['ip'] = 'localhost'
    if 'id' not in all_inputs['resource']:
        all_inputs['resource']['id'] = 'local-resource'
    if 'schedulerType' not in all_inputs['resource']:
        all_inputs['resource']['schedulerType'] = ''

    # Create working directory
    if args.work_dir:
        work_dir = args.work_dir
        work_dir.mkdir(parents=True, exist_ok=True)
        cleanup_work_dir = False
    else:
        work_dir = Path(tempfile.mkdtemp(prefix='workflow_'))
        cleanup_work_dir = not args.keep_work_dir

    try:
        # Set up environment variables
        env_vars = {
            'PW_WORKFLOW_NAME': args.workflow.parent.name,
            'PW_JOB_NUMBER': '1',
            'PW_USER': os.environ.get('USER', 'testuser'),
            'PW_PLATFORM_HOST': 'localhost',
            'PW_PARENT_JOB_DIR': str(work_dir),
            'DEBUG': 'true' if args.verbose else '',
        }

        context = ExecutionContext(
            inputs=all_inputs,
            sessions={},
            job_outputs={},
            env_vars=env_vars,
            work_dir=work_dir,
            dry_run=args.dry_run,
            verbose=args.verbose,
        )

        # Copy workflow files to work directory
        workflow_name = all_inputs.get('workflow_dir', args.workflow.parent.name)
        dest_workflow_dir = work_dir / 'workflows' / workflow_name
        dest_workflow_dir.mkdir(parents=True, exist_ok=True)

        for f in args.workflow.parent.iterdir():
            if f.is_file():
                shutil.copy2(f, dest_workflow_dir)

        # Copy utils
        utils_src = args.workflow.parent.parent.parent / 'utils'
        if utils_src.exists():
            utils_dest = work_dir / 'utils'
            shutil.copytree(utils_src, utils_dest, dirs_exist_ok=True)

        runner = WorkflowRunner(args.workflow, context)
        success = runner.run()

        if not args.dry_run:
            print(f"\nWork directory: {work_dir}")
            if cleanup_work_dir:
                print("(will be cleaned up, use --keep-work-dir to preserve)")

        return 0 if success else 1

    finally:
        if cleanup_work_dir and work_dir.exists():
            shutil.rmtree(work_dir)


if __name__ == '__main__':
    sys.exit(main())
