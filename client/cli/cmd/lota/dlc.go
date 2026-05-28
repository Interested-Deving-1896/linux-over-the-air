// dlc.go — lota dlc subcommand (Downloadable Content)

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"
)

var dlcCmd = &cobra.Command{
	Use:   "dlc",
	Short: "Manage downloadable content packages",
}

var dlcListCmd = &cobra.Command{
	Use:   "list",
	Short: "List installed DLC packages",
	RunE: func(cmd *cobra.Command, args []string) error {
		installDir := dlcInstallDir()
		entries, err := os.ReadDir(installDir)
		if os.IsNotExist(err) {
			fmt.Println("No DLC packages installed.")
			return nil
		}
		if err != nil {
			return err
		}
		if len(entries) == 0 {
			fmt.Println("No DLC packages installed.")
			return nil
		}
		fmt.Printf("%-30s %-12s %s\n", "ID", "VERSION", "SIZE")
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			meta := readDlcMeta(filepath.Join(installDir, e.Name()))
			fmt.Printf("%-30s %-12s %s\n",
				e.Name(),
				orUnknown(meta["version"]),
				orUnknown(meta["size"]),
			)
		}
		return nil
	},
}

var dlcInstallCmd = &cobra.Command{
	Use:   "install ID",
	Short: "Install a DLC package",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		id := args[0]
		fmt.Printf("Installing DLC: %s\n", id)
		return runCmd(findBin("dlcservice_util", "lota-dlc"),
			"--install", "--id="+id)
	},
}

var dlcRemoveCmd = &cobra.Command{
	Use:   "remove ID",
	Short: "Remove an installed DLC package",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		id := args[0]
		fmt.Printf("Removing DLC: %s\n", id)
		return runCmd(findBin("dlcservice_util", "lota-dlc"),
			"--uninstall", "--id="+id)
	},
}

func init() {
	dlcCmd.AddCommand(dlcListCmd)
	dlcCmd.AddCommand(dlcInstallCmd)
	dlcCmd.AddCommand(dlcRemoveCmd)
}

func dlcInstallDir() string {
	if dir := os.Getenv("LOTA_DLC_DIR"); dir != "" {
		return dir
	}
	return "/var/lib/lota/dlc"
}

func readDlcMeta(dir string) map[string]string {
	meta := map[string]string{}
	data, err := os.ReadFile(filepath.Join(dir, "meta.json"))
	if err != nil {
		return meta
	}
	_ = json.Unmarshal(data, &meta)
	return meta
}
