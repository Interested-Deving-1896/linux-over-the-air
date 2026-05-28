// channel.go — lota channel subcommand

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/spf13/cobra"
)

var channelCmd = &cobra.Command{
	Use:   "channel",
	Short: "Manage update channels",
}

var channelGetCmd = &cobra.Command{
	Use:   "get",
	Short: "Print the active update channel",
	RunE: func(cmd *cobra.Command, args []string) error {
		if out, err := exec.Command("update_engine_client", "--channel").Output(); err == nil {
			fmt.Print(string(out))
			return nil
		}
		// Fall back to reading config
		channel := readConfig("channels.active", "stable")
		fmt.Println(channel)
		return nil
	},
}

var channelSetCmd = &cobra.Command{
	Use:   "set CHANNEL",
	Short: "Switch to a different update channel",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		channel := args[0]
		valid := map[string]bool{"stable": true, "beta": true, "dev": true, "lts": true}
		if !valid[channel] {
			return fmt.Errorf("unknown channel %q — valid: stable, beta, dev, lts", channel)
		}

		if err := exec.Command("update_engine_client",
			"--channel="+channel, "--follow").Run(); err == nil {
			fmt.Printf("Channel set to: %s\n", channel)
			return nil
		}

		// Fall back to editing /etc/lota/system.toml
		fmt.Printf("update_engine_client not available — updating config directly\n")
		return setConfigChannel(channel)
	},
}

var channelListCmd = &cobra.Command{
	Use:   "list",
	Short: "List available channels",
	RunE: func(cmd *cobra.Command, args []string) error {
		channels := []struct{ name, desc string }{
			{"stable", "Production releases"},
			{"lts", "Long-term support releases"},
			{"beta", "Pre-release testing"},
			{"dev", "Development builds"},
		}
		active := readConfig("channels.active", "stable")
		for _, ch := range channels {
			marker := "  "
			if ch.name == active {
				marker = "* "
			}
			fmt.Printf("%s%-8s %s\n", marker, ch.name, ch.desc)
		}
		return nil
	},
}

func init() {
	channelCmd.AddCommand(channelGetCmd)
	channelCmd.AddCommand(channelSetCmd)
	channelCmd.AddCommand(channelListCmd)
}

func setConfigChannel(channel string) error {
	configPath := "/etc/lota/system.toml"
	data, err := os.ReadFile(configPath)
	if err != nil {
		return fmt.Errorf("reading config: %w", err)
	}
	lines := strings.Split(string(data), "\n")
	for i, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "active =") {
			lines[i] = fmt.Sprintf(`active = "%s"`, channel)
			break
		}
	}
	return os.WriteFile(configPath, []byte(strings.Join(lines, "\n")), 0644)
}
