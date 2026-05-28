// rollback.go — lota rollback subcommand

package main

import (
	"fmt"
	"os/exec"

	"github.com/spf13/cobra"
)

var rollbackCmd = &cobra.Command{
	Use:   "rollback",
	Short: "Roll back to the previous slot",
	Long: `Switch the active boot slot back to the previously running version.

On Linux systems, delegates to confirm-boot.sh --rollback which updates
the bootloader slot priority. On Android, delegates to bootctl-wrapper.sh.

A reboot is required to complete the rollback.`,
	Example: `  lota rollback
  lota rollback --reboot
  lota rollback --dry-run`,
	RunE: func(cmd *cobra.Command, args []string) error {
		reboot, _ := cmd.Flags().GetBool("reboot")
		dryRun, _ := cmd.Flags().GetBool("dry-run")

		// Determine platform: Android or Linux
		isAndroid := isAndroidSystem()

		if dryRun {
			info := gatherStatus(true)
			fmt.Printf("Would roll back: slot %s → slot %s\n",
				orUnknown(info.ActiveSlot), orUnknown(info.InactiveSlot))
			return nil
		}

		var script, subcmd string
		if isAndroid {
			script = runtimeScript("android/bootctl-wrapper.sh")
			subcmd = "set-active"
			info := gatherStatus(true)
			inactive := info.InactiveSlot
			if inactive == "" {
				inactive = "a"
			}
			fmt.Printf("Rolling back to slot %s (Android)\n", inactive)
			if err := runScript(script, "", subcmd, inactive); err != nil {
				return fmt.Errorf("rollback failed: %w", err)
			}
		} else {
			script = runtimeScript("boot/confirm-boot.sh")
			fmt.Println("Rolling back to previous slot (Linux)")
			if err := runScript(script, "", "--rollback"); err != nil {
				return fmt.Errorf("rollback failed: %w", err)
			}
		}

		// Run rollback hooks
		hookScript := runtimeScript("../client/hooks/hook-runner.sh")
		_ = runScript(hookScript, "", "--phase", "rollback")

		fmt.Println("Rollback prepared. Reboot to activate the previous slot.")

		if reboot {
			fmt.Println("Rebooting...")
			return runCmd("systemctl", "reboot")
		}

		return nil
	},
}

func init() {
	rollbackCmd.Flags().Bool("reboot", false, "Reboot immediately after preparing rollback")
	rollbackCmd.Flags().Bool("dry-run", false, "Show what would be done without making changes")
}

// isAndroidSystem returns true if running on an Android device.
func isAndroidSystem() bool {
	// Heuristic: Android has /system/build.prop or ro.build.id property
	if _, err := runCmdOutput("getprop", "ro.build.id"); err == nil {
		return true
	}
	return false
}

func runCmdOutput(name string, args ...string) (string, error) {
	bin := findBin(name)
	if bin == "" {
		return "", fmt.Errorf("%s not found", name)
	}
	import_cmd := exec.Command(bin, args...)
	out, err := import_cmd.Output()
	return string(out), err
}
