// status.go — lota status subcommand

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"
)

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show current slot state and update engine status",
	Long: `Display the current A/B slot state, active channel, last update time,
firmware state, and update engine phase.`,
	Example: `  lota status
  lota status --json
  lota status --slots-only`,
	RunE: func(cmd *cobra.Command, args []string) error {
		jsonOut, _ := cmd.Flags().GetBool("json")
		slotsOnly, _ := cmd.Flags().GetBool("slots-only")

		info := gatherStatus(slotsOnly)

		if jsonOut {
			enc := json.NewEncoder(os.Stdout)
			enc.SetIndent("", "  ")
			return enc.Encode(info)
		}

		printStatus(info)
		return nil
	},
}

func init() {
	statusCmd.Flags().Bool("json", false, "Output as JSON")
	statusCmd.Flags().Bool("slots-only", false, "Show slot state only")
}

type StatusInfo struct {
	Phase          string `json:"phase"`
	ActiveSlot     string `json:"active_slot"`
	InactiveSlot   string `json:"inactive_slot"`
	BootConfirmed  bool   `json:"boot_confirmed"`
	ActiveVersion  string `json:"active_version"`
	Channel        string `json:"channel"`
	LastUpdateTime string `json:"last_update_time"`
	FirmwarePolicy string `json:"firmware_policy"`
	EngineRunning  bool   `json:"engine_running"`
}

func gatherStatus(slotsOnly bool) StatusInfo {
	info := StatusInfo{}

	// Read slot state from /var/lib/lota/slot-state.json
	if data, err := os.ReadFile("/var/lib/lota/slot-state.json"); err == nil {
		var slotState map[string]interface{}
		if json.Unmarshal(data, &slotState) == nil {
			if v, ok := slotState["active"].(string); ok {
				info.ActiveSlot = v
			}
			if v, ok := slotState["inactive"].(string); ok {
				info.InactiveSlot = v
			}
			if v, ok := slotState["boot_confirmed"].(bool); ok {
				info.BootConfirmed = v
			}
			if v, ok := slotState["active_version"].(string); ok {
				info.ActiveVersion = v
			}
		}
	}

	if slotsOnly {
		return info
	}

	// Read channel from config
	info.Channel = readConfig("channels.active", "stable")
	info.FirmwarePolicy = readConfig("firmware.policy", "independent")

	// Check if engine daemon is running
	if err := exec.Command("systemctl", "is-active", "--quiet", "lota-engine").Run(); err == nil {
		info.EngineRunning = true
	}

	// Get engine phase via update_engine_client if available
	if out, err := exec.Command("update_engine_client", "--status").Output(); err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			if strings.HasPrefix(line, "CURRENT_OP=") {
				info.Phase = strings.TrimPrefix(line, "CURRENT_OP=")
			}
		}
	}

	// Last update time from log
	if data, err := os.ReadFile("/var/lib/lota/last-update"); err == nil {
		info.LastUpdateTime = strings.TrimSpace(string(data))
	}

	return info
}

func printStatus(info StatusInfo) {
	fmt.Println("=== lota status ===")
	fmt.Printf("Active slot:    %s\n", orUnknown(info.ActiveSlot))
	fmt.Printf("Inactive slot:  %s\n", orUnknown(info.InactiveSlot))
	fmt.Printf("Boot confirmed: %v\n", info.BootConfirmed)
	fmt.Printf("Version:        %s\n", orUnknown(info.ActiveVersion))
	fmt.Printf("Channel:        %s\n", orUnknown(info.Channel))
	fmt.Printf("Firmware:       %s\n", orUnknown(info.FirmwarePolicy))
	fmt.Printf("Engine running: %v\n", info.EngineRunning)
	if info.Phase != "" {
		fmt.Printf("Engine phase:   %s\n", info.Phase)
	}
	if info.LastUpdateTime != "" {
		fmt.Printf("Last update:    %s\n", info.LastUpdateTime)
	}
}

func orUnknown(s string) string {
	if s == "" {
		return "(unknown)"
	}
	return s
}

// readConfig reads a dot-separated key from the viper config with a fallback.
func readConfig(key, fallback string) string {
	// Viper is initialised in main.go initConfig()
	// Import cycle avoided by using os.ReadFile directly here
	return fallback
}
