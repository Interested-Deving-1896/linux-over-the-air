// update.go — lota update subcommand

package main

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/spf13/cobra"
)

var updateCmd = &cobra.Command{
	Use:   "update",
	Short: "Check for and apply an OTA update",
	Long: `Check the configured update server for a newer version and apply it.

The update is written to the inactive A/B slot. The system must be rebooted
to activate the new slot. Boot confirmation runs automatically on first boot.

Firmware updates (fwupd) are applied according to the policy in system.toml:
  before_os  — firmware first, then OS update
  after_os   — OS update first, then firmware on next boot
  independent — fwupd manages its own schedule`,
	Example: `  lota update
  lota update --check-only
  lota update --channel beta
  lota update --reboot`,
	RunE: func(cmd *cobra.Command, args []string) error {
		checkOnly, _ := cmd.Flags().GetBool("check-only")
		channel, _ := cmd.Flags().GetString("channel")
		reboot, _ := cmd.Flags().GetBool("reboot")
		force, _ := cmd.Flags().GetBool("force")

		// Delegate to the update engine daemon via update-engine-client,
		// or invoke the engine binary directly if daemon is not running.
		engineClient := findBin("update_engine_client", "lota-engine")

		if engineClient == "" {
			return fmt.Errorf("update engine not found — install lota-engine or update_engine_client")
		}

		engineArgs := []string{}

		if checkOnly {
			engineArgs = append(engineArgs, "--check_for_update")
			return runCmd(engineClient, engineArgs...)
		}

		if channel != "" {
			engineArgs = append(engineArgs, "--channel="+channel)
		}
		if force {
			engineArgs = append(engineArgs, "--force")
		}

		engineArgs = append(engineArgs, "--update", "--follow")

		if err := runCmd(engineClient, engineArgs...); err != nil {
			return err
		}

		if reboot {
			fmt.Println("Update applied. Rebooting...")
			return runCmd("systemctl", "reboot")
		}

		fmt.Println("Update applied. Reboot to activate the new slot.")
		return nil
	},
}

func init() {
	updateCmd.Flags().Bool("check-only", false, "Check for updates without applying")
	updateCmd.Flags().String("channel", "", "Override active channel for this update")
	updateCmd.Flags().Bool("reboot", false, "Reboot immediately after applying update")
	updateCmd.Flags().Bool("force", false, "Apply update even if already on latest version")
}

// findBin returns the path to the first binary found in PATH, or "".
func findBin(names ...string) string {
	for _, name := range names {
		if p, err := exec.LookPath(name); err == nil {
			return p
		}
	}
	return ""
}

// runCmd runs a command with args, inheriting stdio.
func runCmd(name string, args ...string) error {
	c := exec.Command(name, args...)
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	c.Stdin = os.Stdin
	return c.Run()
}
