// Package install detects OS and helps install the OCI CLI.
package install

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

// DetectOS returns darwin / windows / linux (or other GOOS).
func DetectOS() string {
	return runtime.GOOS
}

// IsTTY reports whether stdin is interactive.
func IsTTY() bool {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return (fi.Mode() & os.ModeCharDevice) != 0
}

// CLIAvailable returns true if `oci --version` succeeds.
func CLIAvailable() bool {
	cmd := exec.Command("oci", "--version")
	return cmd.Run() == nil
}

// CLIVersion returns version string or empty.
func CLIVersion() string {
	out, err := exec.Command("oci", "--version").CombinedOutput()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// EnsureOCICLI checks PATH; if missing, tries install guidance / optional install.
// Returns nil if CLI is usable after the call (or already was).
func EnsureOCICLI(r *bufio.Reader) error {
	osName := DetectOS()
	fmt.Printf("偵測作業系統: %s\n", osName)

	if CLIAvailable() {
		fmt.Printf("已找到 OCI CLI: %s\n", CLIVersion())
		return nil
	}
	fmt.Println("未在 PATH 找到可用的 `oci`，嘗試安裝指引…")

	switch osName {
	case "darwin":
		return ensureDarwin(r)
	case "linux":
		return ensureLinux(r)
	case "windows":
		return ensureWindows(r)
	default:
		printOfficialDocs()
		return fmt.Errorf("請手動安裝 OCI CLI 後重試")
	}
}

func printOfficialDocs() {
	fmt.Println("官方安裝說明:")
	fmt.Println("  https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm")
}

func ensureDarwin(r *bufio.Reader) error {
	if _, err := exec.LookPath("brew"); err == nil {
		fmt.Println("偵測到 Homebrew。建議: brew install oci-cli")
		if IsTTY() && confirm(r, "是否現在執行 brew install oci-cli？[y/N] ") {
			cmd := exec.Command("brew", "install", "oci-cli")
			cmd.Stdout = os.Stdout
			cmd.Stderr = os.Stderr
			cmd.Stdin = os.Stdin
			if err := cmd.Run(); err != nil {
				fmt.Printf("brew 安裝失敗: %v\n", err)
				printOfficialDocs()
				return err
			}
			if CLIAvailable() {
				fmt.Printf("安裝成功: %s\n", CLIVersion())
				return nil
			}
		}
	} else {
		fmt.Println("未找到 brew。請參考官方文件安裝 OCI CLI:")
		printOfficialDocs()
	}
	if CLIAvailable() {
		return nil
	}
	return fmt.Errorf("OCI CLI 尚未可用")
}

func ensureLinux(r *bufio.Reader) error {
	scriptURL := "https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh"
	fmt.Println("Linux 建議使用官方安裝腳本:")
	fmt.Printf("  bash -c \"$(curl -L %s)\"\n", scriptURL)
	fmt.Println("或依發行版套件管理器安裝（若有文件支援）。")
	printOfficialDocs()

	if !IsTTY() {
		fmt.Println("（非 TTY：僅印出指令，不自動執行）")
		return fmt.Errorf("OCI CLI 尚未可用（非互動模式）")
	}
	if confirm(r, "是否下載並執行官方安裝腳本？[y/N] ") {
		cmd := exec.Command("bash", "-c", fmt.Sprintf(`curl -L "%s" | bash`, scriptURL))
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		cmd.Stdin = os.Stdin
		if err := cmd.Run(); err != nil {
			fmt.Printf("安裝腳本失敗: %v\n", err)
			return err
		}
		if CLIAvailable() {
			fmt.Printf("安裝成功: %s\n", CLIVersion())
			return nil
		}
		fmt.Println("腳本結束但仍找不到 oci；請確認 PATH（常在 ~/bin 或 ~/.local/bin）。")
	}
	return fmt.Errorf("OCI CLI 尚未可用")
}

func ensureWindows(r *bufio.Reader) error {
	fmt.Println("Windows 安裝指引:")
	fmt.Println("  1) MSI: 從官方文件下載安裝套件")
	fmt.Println("  2) 或: pip install oci-cli")
	printOfficialDocs()
	fmt.Println("正在執行 where oci …")
	cmd := exec.Command("where", "oci")
	out, err := cmd.CombinedOutput()
	fmt.Print(string(out))
	if err == nil && CLIAvailable() {
		fmt.Printf("已找到: %s\n", CLIVersion())
		return nil
	}
	_ = r // unused on windows interactive beyond guidance
	return fmt.Errorf("OCI CLI 尚未可用；請依上述指引安裝")
}

func confirm(r *bufio.Reader, prompt string) bool {
	fmt.Print(prompt)
	line, _ := r.ReadString('\n')
	line = strings.TrimSpace(strings.ToLower(line))
	return line == "y" || line == "yes"
}
