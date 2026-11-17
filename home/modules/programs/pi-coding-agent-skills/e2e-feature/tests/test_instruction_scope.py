"""Regression checks for verifier-only queue instructions and workflow routing."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import unittest


FEATURE = Path(__file__).resolve().parents[1]
PROGRAMS = FEATURE.parents[1]


class InstructionScopeTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("nix-instantiate"), "Nix is required to render the common module")
    def test_rendered_common_agents_have_no_queue_mandate(self):
        # Evaluate the module's actual text expressions for both queue settings.
        # Only option constructors are stubbed; no Nixpkgs evaluation is needed.
        module = PROGRAMS / "ai-agent-common/default.nix"
        for enabled in (True, False):
            with self.subTest(qex_enabled=enabled):
                expression = '''let
                  lib = rec {
                    mkEnableOption = _: {};
                    mkDefault = value: value;
                    mkIf = enabled: value: if enabled then value else {};
                    optionalString = enabled: value: if enabled then value else "";
                  };
                  module = import %s {
                    inherit lib; pkgs = {};
                    config.my.programs = {
                      ai-agent-common.enable = true;
                      pi-coding-agent.enable = true;
                      qex.enable = %s;
                    };
                  };
                in {
                  files = module.config.home.file;
                  queueEnabled = module.config.my.programs.qex.enable;
                }''' % (module, str(enabled).lower())
                rendered = json.loads(subprocess.check_output(
                    ["nix-instantiate", "--eval", "--strict", "--json", "--expr", expression], text=True))
                self.assertTrue(rendered["queueEnabled"])
                self.assertEqual(set(rendered["files"]), {".codex/AGENTS.md", ".claude/CLAUDE.md", ".pi/agent/AGENTS.md"})
                for entry in rendered["files"].values():
                    self.assertNotRegex(entry["text"], r"(?i)qex|agent-job")

    def test_queue_reference_is_explicit_and_not_a_global_skill(self):
        module = (PROGRAMS / "qex/default.nix").read_text()
        self.assertNotIn('home.file.".pi/agent/skills/qex', module)
        self.assertIn('xdg.configFile."qex/AGENT.md".source', module)
        self.assertIn('xdg.configFile."qex/e2e-resources.md".source', module)
        reference = (PROGRAMS / "pi-coding-agent-skills/qex/SKILL.md").read_text()
        self.assertIn("disable-model-invocation: true", reference)
        self.assertIn("only to this verifier", (FEATURE / "references/verifier.md").read_text())
        self.assertIn('workflow: "qex-wait"', reference)
        self.assertIn("without a model worker or polling", reference)

    def test_verifier_brief_owns_admission_and_evidence_not_fixes(self):
        brief = (FEATURE / "references/verifier.md").read_text()
        for required in ["verification-only", "~/.config/qex/AGENT.md", "Gradle builds", "complete E2E stacks",
                         "agent-job run <profile>", "agent-job run --e2e <name>", "transitive prerequisites",
                         "No short status/sleep polling", "Do not edit product code", "receipt", "before qex admission",
                         "Never enqueue a parent helper", "AGENT_JOB_ACTIVE=1", "explicit bash timeout",
                         "do not request nested subagent tools", "no model subdelegation"]:
            self.assertIn(required, brief)

    def test_workflow_references_preserve_verifier_boundary(self):
        for relative in ["SKILL.md", "references/verification.md", "references/projects.md",
                         "references/host-move.md", "references/qex-resources.md", "references/capability-and-repairs.md",
                         "references/latency.md"]:
            with self.subTest(path=relative):
                text = (FEATURE / relative).read_text()
                self.assertIn("verifier", text)
                self.assertNotIn("Allowlisted worker development commands use", text)
                self.assertNotIn("read `~/.config/qex/AGENT.md` and use `flock", text)
                # All local Markdown reference links must remain discoverable.
                for target in re.findall(r"\]\(([^)#]+)(?:#[^)]*)?\)", text):
                    if "://" not in target:
                        self.assertTrue(((FEATURE / relative).parent / target).exists(), target)
        skill = (FEATURE / "SKILL.md").read_text()
        implementation = skill.split("## Implement\n", 1)[1].split("## Test gate", 1)[0]
        self.assertNotIn("agent-job run", implementation)
        self.assertNotIn("runs.run(", implementation)
        self.assertIn("Run normal development checks directly", implementation)
        self.assertIn("directly in the main session", implementation)
        self.assertIn("entire dependency closure", skill)
        verification = (FEATURE / "references/verification.md").read_text()
        self.assertIn("including any transitive prerequisite", verification)
        self.assertIn("only non-qex commands and prerequisites", verification)


if __name__ == "__main__":
    unittest.main()
