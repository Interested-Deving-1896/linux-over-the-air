// main.go — lota CLI entry point
//
// lota is the command-line interface for linux-over-the-air.
// It delegates all device interactions to the runtime shell scripts
// in runtime/ and communicates with the update engine daemon via
// D-Bus (UpdateEngineInterface) or direct invocation.
//
// Usage:
//   lota update              Check for and apply an update
//   lota status              Show current slot and update state
//   lota rollback            Roll back to the previous slot
//   lota android <cmd>       Android/AOSP OTA operations
//   lota channel <cmd>       Channel management
//   lota dlc <cmd>           Downloadable content management
//   lota version             Print lota version

package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
)

var (
	cfgFile string
	verbose bool
)

var rootCmd = &cobra.Command{
	Use:   "lota",
	Short: "linux-over-the-air update client",
	Long: `lota — unified OTA update client for Linux and Android systems.

Supports A/B slot updates, delta payloads, fwupd firmware coordination,
Incus-based staging, and Android/AOSP OTA via fastboot, ADB, and network.`,
	SilenceUsage: true,
}

func main() {
	if err := rootCmd.Execute(); err != nil {
		os.Exit(1)
	}
}

func init() {
	cobra.OnInitialize(initConfig)

	rootCmd.PersistentFlags().StringVar(&cfgFile, "config", "",
		"Config file (default: /etc/lota/system.toml)")
	rootCmd.PersistentFlags().BoolVarP(&verbose, "verbose", "v", false,
		"Enable verbose output")

	rootCmd.AddCommand(updateCmd)
	rootCmd.AddCommand(statusCmd)
	rootCmd.AddCommand(rollbackCmd)
	rootCmd.AddCommand(androidCmd)
	rootCmd.AddCommand(channelCmd)
	rootCmd.AddCommand(dlcCmd)
	rootCmd.AddCommand(versionCmd)
}

func initConfig() {
	if cfgFile != "" {
		viper.SetConfigFile(cfgFile)
	} else {
		viper.AddConfigPath("/etc/lota")
		viper.AddConfigPath("config")
		viper.SetConfigName("system")
		viper.SetConfigType("toml")
	}
	viper.AutomaticEnv()
	_ = viper.ReadInConfig()
}

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print lota version",
	Run: func(cmd *cobra.Command, args []string) {
		fmt.Println("lota 0.1.0")
	},
}
