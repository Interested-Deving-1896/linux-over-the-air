// android.go — lota android subcommand
//
// Provides Android/AOSP OTA operations as a first-class lota subcommand.
// Delegates to the runtime shell scripts in runtime/android/ for all
// device interactions (fastboot, adb, avbtool, bootctl).
//
// Subcommands:
//   lota android flash      Flash a bundle to an Android device via fastboot
//   lota android sideload   Deliver a package via adb sideload
//   lota android sign       Sign partition images with AVB
//   lota android status     Show device slot and AVB state
//   lota android waydroid   Manage Waydroid container updates
//   lota android halium     Manage Halium layer updates
//   lota android payload    Inspect or create payload.bin

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"

	"github.com/spf13/cobra"
)

// androidCmd is the root of the `lota android` subcommand tree.
var androidCmd = &cobra.Command{
	Use:   "android",
	Short: "Android/AOSP OTA operations",
	Long: `Manage OTA updates for Android devices and Android-on-Linux environments.

Supports:
  - A/B slot flashing via fastboot/fastbootd
  - ADB sideload (recovery mode)
  - AVB (Android Verified Boot) signing
  - Waydroid container image updates
  - Halium hardware adaptation layer updates
  - payload.bin creation and inspection`,
}

// ── flash ────────────────────────────────────────────────────────────────────

var androidFlashCmd = &cobra.Command{
	Use:   "flash",
	Short: "Flash an OTA bundle to an Android device via fastboot",
	Example: `  lota android flash --bundle ./bundle-1.2.0-arm64.lota --serial ABC123
  lota android flash --gsi --system system.img --serial ABC123 --wipe`,
	RunE: func(cmd *cobra.Command, args []string) error {
		bundle, _ := cmd.Flags().GetString("bundle")
		serial, _ := cmd.Flags().GetString("serial")
		slot, _ := cmd.Flags().GetString("slot")
		gsi, _ := cmd.Flags().GetBool("gsi")
		wipe, _ := cmd.Flags().GetBool("wipe")
		system, _ := cmd.Flags().GetString("system")
		vbmeta, _ := cmd.Flags().GetString("vbmeta")

		script := runtimeScript("android/fastboot-flash.sh")

		if gsi {
			return runScript(script, serial, "flash-gsi",
				"--system", system,
				optFlag("--vbmeta", vbmeta),
				boolFlag("--wipe", wipe),
			)
		}

		if bundle == "" {
			return fmt.Errorf("--bundle required (or use --gsi for GSI flashing)")
		}

		// Extract images from bundle directory
		bootImg := filepath.Join(bundle, "boot.img")
		systemImg := filepath.Join(bundle, "system.img")
		vendorImg := filepath.Join(bundle, "vendor.img")
		vbmetaImg := filepath.Join(bundle, "vbmeta.img")

		scriptArgs := []string{"flash-all",
			"--slot", slot,
		}
		if fileExists(bootImg) {
			scriptArgs = append(scriptArgs, "--boot", bootImg)
		}
		if fileExists(systemImg) {
			scriptArgs = append(scriptArgs, "--system", systemImg)
		}
		if fileExists(vendorImg) {
			scriptArgs = append(scriptArgs, "--vendor", vendorImg)
		}
		if fileExists(vbmetaImg) {
			scriptArgs = append(scriptArgs, "--vbmeta", vbmetaImg)
		} else if vbmeta != "" {
			scriptArgs = append(scriptArgs, "--vbmeta", vbmeta)
		}

		return runScriptArgs(script, serial, scriptArgs)
	},
}

// ── sideload ─────────────────────────────────────────────────────────────────

var androidSideloadCmd = &cobra.Command{
	Use:   "sideload",
	Short: "Deliver an OTA package via adb sideload",
	Example: `  lota android sideload --package update.zip --serial ABC123
  lota android sideload --package update.zip --reboot-recovery`,
	RunE: func(cmd *cobra.Command, args []string) error {
		pkg, _ := cmd.Flags().GetString("package")
		serial, _ := cmd.Flags().GetString("serial")
		rebootRecovery, _ := cmd.Flags().GetBool("reboot-recovery")
		timeout, _ := cmd.Flags().GetInt("timeout")

		if pkg == "" {
			return fmt.Errorf("--package required")
		}

		script := runtimeScript("android/adb-sideload.sh")

		if rebootRecovery {
			if err := runScript(script, serial, "reboot-sideload"); err != nil {
				return err
			}
			fmt.Println("Waiting for device to enter sideload mode...")
			if err := runScript(script, serial, "wait-for-device",
				"--timeout", fmt.Sprintf("%d", timeout)); err != nil {
				return err
			}
		}

		return runScript(script, serial, "sideload",
			"--package", pkg,
			"--timeout", fmt.Sprintf("%d", timeout),
		)
	},
}

// ── sign ─────────────────────────────────────────────────────────────────────

var androidSignCmd = &cobra.Command{
	Use:   "sign",
	Short: "Sign Android partition images with AVB",
	Example: `  lota android sign --boot boot.img --system system.img --key oem.pem --output vbmeta.img
  lota android sign --disable-verification --output vbmeta.img`,
	RunE: func(cmd *cobra.Command, args []string) error {
		boot, _ := cmd.Flags().GetString("boot")
		system, _ := cmd.Flags().GetString("system")
		vendor, _ := cmd.Flags().GetString("vendor")
		key, _ := cmd.Flags().GetString("key")
		output, _ := cmd.Flags().GetString("output")
		disableVerification, _ := cmd.Flags().GetBool("disable-verification")

		script := runtimeScript("android/avb-sign.sh")

		if disableVerification {
			return runScript(script, "", "disable-verification", "--output", output)
		}

		if key == "" {
			return fmt.Errorf("--key required (or use --disable-verification)")
		}

		// Sign individual partitions first
		if boot != "" {
			if err := runScript(script, "", "sign-boot", "--image", boot, "--key", key); err != nil {
				return fmt.Errorf("signing boot: %w", err)
			}
		}
		if system != "" {
			if err := runScript(script, "", "sign-system", "--image", system, "--key", key); err != nil {
				return fmt.Errorf("signing system: %w", err)
			}
		}
		if vendor != "" {
			if err := runScript(script, "", "sign-vendor", "--image", vendor, "--key", key); err != nil {
				return fmt.Errorf("signing vendor: %w", err)
			}
		}

		// Build vbmeta
		if output != "" {
			vbmetaArgs := []string{"make-vbmeta", "--output", output, "--key", key}
			if boot != "" {
				vbmetaArgs = append(vbmetaArgs, "--boot", boot)
			}
			if system != "" {
				vbmetaArgs = append(vbmetaArgs, "--system", system)
			}
			if vendor != "" {
				vbmetaArgs = append(vbmetaArgs, "--vendor", vendor)
			}
			return runScriptArgs(script, "", vbmetaArgs)
		}

		return nil
	},
}

// ── status ───────────────────────────────────────────────────────────────────

var androidStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show Android device slot and AVB state",
	RunE: func(cmd *cobra.Command, args []string) error {
		serial, _ := cmd.Flags().GetString("serial")
		transport, _ := cmd.Flags().GetString("transport")

		switch transport {
		case "fastboot":
			return runScript(runtimeScript("android/fastboot-flash.sh"), serial, "status")
		case "adb", "":
			return runScript(runtimeScript("android/adb-sideload.sh"), serial, "status")
		default:
			return fmt.Errorf("unknown transport: %s (use adb or fastboot)", transport)
		}
	},
}

// ── waydroid ─────────────────────────────────────────────────────────────────

var androidWaydroidCmd = &cobra.Command{
	Use:   "waydroid",
	Short: "Manage Waydroid Android container updates",
	Example: `  lota android waydroid update
  lota android waydroid sideload-apk --apk MyApp.apk
  lota android waydroid sideload-obb --obb main.obb --package com.example.app
  lota android waydroid status`,
	RunE: func(cmd *cobra.Command, args []string) error {
		if len(args) == 0 {
			return cmd.Help()
		}
		script := runtimeScript("android/waydroid-ota.sh")
		subcmd := args[0]

		switch subcmd {
		case "update":
			system, _ := cmd.Flags().GetString("system")
			vendor, _ := cmd.Flags().GetString("vendor")
			scriptArgs := []string{"update"}
			if system != "" {
				scriptArgs = append(scriptArgs, "--system", system)
			}
			if vendor != "" {
				scriptArgs = append(scriptArgs, "--vendor", vendor)
			}
			return runScriptArgs(script, "", scriptArgs)
		case "sideload-apk":
			apk, _ := cmd.Flags().GetString("apk")
			return runScript(script, "", "sideload-apk", "--apk", apk)
		case "sideload-obb":
			obb, _ := cmd.Flags().GetString("obb")
			pkg, _ := cmd.Flags().GetString("package")
			return runScript(script, "", "sideload-obb", "--obb", obb, "--package", pkg)
		case "status", "start", "stop", "rollback", "check-update":
			return runScript(script, "", subcmd)
		default:
			return fmt.Errorf("unknown waydroid subcommand: %s", subcmd)
		}
	},
}

// ── halium ───────────────────────────────────────────────────────────────────

var androidHaliumCmd = &cobra.Command{
	Use:   "halium",
	Short: "Manage Halium hardware adaptation layer updates",
	Example: `  lota android halium update-full --rootfs rootfs.img --system system.img --boot boot.img
  lota android halium status`,
	RunE: func(cmd *cobra.Command, args []string) error {
		if len(args) == 0 {
			return cmd.Help()
		}
		script := runtimeScript("android/halium-ota.sh")
		subcmd := args[0]

		switch subcmd {
		case "update-rootfs":
			image, _ := cmd.Flags().GetString("image")
			return runScript(script, "", "update-rootfs", "--image", image)
		case "update-halium":
			system, _ := cmd.Flags().GetString("system")
			vendor, _ := cmd.Flags().GetString("vendor")
			scriptArgs := []string{"update-halium", "--system", system}
			if vendor != "" {
				scriptArgs = append(scriptArgs, "--vendor", vendor)
			}
			return runScriptArgs(script, "", scriptArgs)
		case "update-kernel":
			boot, _ := cmd.Flags().GetString("boot")
			return runScript(script, "", "update-kernel", "--boot", boot)
		case "update-full":
			rootfs, _ := cmd.Flags().GetString("rootfs")
			system, _ := cmd.Flags().GetString("system")
			boot, _ := cmd.Flags().GetString("boot")
			vendor, _ := cmd.Flags().GetString("vendor")
			scriptArgs := []string{"update-full",
				"--rootfs", rootfs, "--system", system, "--boot", boot}
			if vendor != "" {
				scriptArgs = append(scriptArgs, "--vendor", vendor)
			}
			return runScriptArgs(script, "", scriptArgs)
		case "status", "rollback":
			return runScript(script, "", subcmd)
		default:
			return fmt.Errorf("unknown halium subcommand: %s", subcmd)
		}
	},
}

// ── payload ──────────────────────────────────────────────────────────────────

var androidPayloadCmd = &cobra.Command{
	Use:   "payload",
	Short: "Create or inspect Android payload.bin",
	Example: `  lota android payload inspect --payload payload.bin
  lota android payload create-full --target-files target.zip --output ./out
  lota android payload create-zip --payload ./out --output update.zip`,
	RunE: func(cmd *cobra.Command, args []string) error {
		if len(args) == 0 {
			return cmd.Help()
		}
		script := runtimeScript("android/payload-tool.sh")
		subcmd := args[0]

		switch subcmd {
		case "inspect":
			payload, _ := cmd.Flags().GetString("payload")
			return runScript(script, "", "inspect", "--payload", payload)
		case "verify":
			payload, _ := cmd.Flags().GetString("payload")
			pubkey, _ := cmd.Flags().GetString("pubkey")
			return runScript(script, "", "verify", "--payload", payload,
				optFlag("--pubkey", pubkey))
		case "create-full":
			targetFiles, _ := cmd.Flags().GetString("target-files")
			output, _ := cmd.Flags().GetString("output")
			key, _ := cmd.Flags().GetString("key")
			scriptArgs := []string{"create-full",
				"--target-files", targetFiles, "--output", output}
			if key != "" {
				scriptArgs = append(scriptArgs, "--key", key)
			}
			return runScriptArgs(script, "", scriptArgs)
		case "create-delta":
			sourceFiles, _ := cmd.Flags().GetString("source-files")
			targetFiles, _ := cmd.Flags().GetString("target-files")
			output, _ := cmd.Flags().GetString("output")
			return runScript(script, "", "create-delta",
				"--source-files", sourceFiles,
				"--target-files", targetFiles,
				"--output", output)
		case "create-zip":
			payload, _ := cmd.Flags().GetString("payload")
			output, _ := cmd.Flags().GetString("output")
			return runScript(script, "", "create-zip",
				"--payload", payload, "--output", output)
		case "extract":
			payload, _ := cmd.Flags().GetString("payload")
			partition, _ := cmd.Flags().GetString("partition")
			output, _ := cmd.Flags().GetString("output")
			return runScript(script, "", "extract",
				"--payload", payload, "--partition", partition, "--output", output)
		default:
			return fmt.Errorf("unknown payload subcommand: %s", subcmd)
		}
	},
}

// ── init ─────────────────────────────────────────────────────────────────────

func init() {
	// flash flags
	androidFlashCmd.Flags().String("bundle", "", "Path to .lota bundle directory")
	androidFlashCmd.Flags().String("serial", "", "Device serial number")
	androidFlashCmd.Flags().String("slot", "b", "Target slot (a or b)")
	androidFlashCmd.Flags().Bool("gsi", false, "GSI flash mode")
	androidFlashCmd.Flags().Bool("wipe", false, "Wipe userdata after GSI flash")
	androidFlashCmd.Flags().String("system", "", "System image path (GSI mode)")
	androidFlashCmd.Flags().String("vbmeta", "", "vbmeta image path")

	// sideload flags
	androidSideloadCmd.Flags().String("package", "", "OTA package path (update.zip or payload.bin)")
	androidSideloadCmd.Flags().String("serial", "", "Device serial number")
	androidSideloadCmd.Flags().Bool("reboot-recovery", false, "Reboot device to recovery/sideload first")
	androidSideloadCmd.Flags().Int("timeout", 300, "Sideload timeout in seconds")

	// sign flags
	androidSignCmd.Flags().String("boot", "", "boot.img to sign")
	androidSignCmd.Flags().String("system", "", "system.img to sign")
	androidSignCmd.Flags().String("vendor", "", "vendor.img to sign")
	androidSignCmd.Flags().String("key", "", "AVB signing key (PEM)")
	androidSignCmd.Flags().String("output", "vbmeta.img", "Output vbmeta.img path")
	androidSignCmd.Flags().Bool("disable-verification", false, "Produce VERIFICATION_DISABLED vbmeta")

	// status flags
	androidStatusCmd.Flags().String("serial", "", "Device serial number")
	androidStatusCmd.Flags().String("transport", "adb", "Transport: adb or fastboot")

	// waydroid flags
	androidWaydroidCmd.Flags().String("system", "", "system.img path")
	androidWaydroidCmd.Flags().String("vendor", "", "vendor.img path")
	androidWaydroidCmd.Flags().String("apk", "", "APK file path")
	androidWaydroidCmd.Flags().String("obb", "", "OBB file path")
	androidWaydroidCmd.Flags().String("package", "", "Android package name (for OBB)")

	// halium flags
	androidHaliumCmd.Flags().String("rootfs", "", "Linux rootfs image")
	androidHaliumCmd.Flags().String("system", "", "Android system image")
	androidHaliumCmd.Flags().String("boot", "", "Boot/kernel image")
	androidHaliumCmd.Flags().String("vendor", "", "Android vendor image")
	androidHaliumCmd.Flags().String("image", "", "Image path (for single-partition commands)")

	// payload flags
	androidPayloadCmd.Flags().String("payload", "", "payload.bin path")
	androidPayloadCmd.Flags().String("target-files", "", "AOSP target-files zip")
	androidPayloadCmd.Flags().String("source-files", "", "AOSP source target-files zip (delta)")
	androidPayloadCmd.Flags().String("output", "", "Output directory or file")
	androidPayloadCmd.Flags().String("key", "", "Signing key path")
	androidPayloadCmd.Flags().String("pubkey", "", "Public key for verification")
	androidPayloadCmd.Flags().String("partition", "", "Partition name to extract")

	// Wire subcommands
	androidCmd.AddCommand(androidFlashCmd)
	androidCmd.AddCommand(androidSideloadCmd)
	androidCmd.AddCommand(androidSignCmd)
	androidCmd.AddCommand(androidStatusCmd)
	androidCmd.AddCommand(androidWaydroidCmd)
	androidCmd.AddCommand(androidHaliumCmd)
	androidCmd.AddCommand(androidPayloadCmd)
}

// ── helpers ──────────────────────────────────────────────────────────────────

// runtimeScript returns the path to a runtime shell script relative to the
// lota binary location, falling back to PATH lookup.
func runtimeScript(name string) string {
	// Try relative to binary first (installed layout: bin/lota, runtime/android/*)
	if exe, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(exe), "..", "runtime", name)
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	// Fall back to LOTA_RUNTIME_DIR env
	if dir := os.Getenv("LOTA_RUNTIME_DIR"); dir != "" {
		return filepath.Join(dir, name)
	}
	// Last resort: just the basename (must be on PATH)
	return filepath.Base(name)
}

// runScript runs a shell script with a subcommand and optional args.
// If serial is non-empty, sets LOTA_ANDROID_SERIAL in the environment.
func runScript(script, serial, subcmd string, args ...string) error {
	allArgs := append([]string{subcmd}, filterEmpty(args)...)
	return runScriptArgs(script, serial, allArgs)
}

func runScriptArgs(script, serial string, args []string) error {
	cmd := exec.Command("bash", append([]string{script}, args...)...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if serial != "" {
		cmd.Env = append(os.Environ(), "LOTA_ANDROID_SERIAL="+serial)
	} else {
		cmd.Env = os.Environ()
	}
	return cmd.Run()
}

func optFlag(flag, value string) string {
	if value == "" {
		return ""
	}
	return flag + "=" + value
}

func boolFlag(flag string, v bool) string {
	if v {
		return flag
	}
	return ""
}

func filterEmpty(args []string) []string {
	out := make([]string, 0, len(args))
	for _, a := range args {
		if a != "" {
			out = append(out, a)
		}
	}
	return out
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// Suppress unused import warning for runtime package
var _ = runtime.GOOS
