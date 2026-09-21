// Package schedule installs cron / Task Scheduler entries for oracle-free-camp.
package schedule

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/Shuhimoon/tools/oracle-free-vm/internal/plan"
)

// Install sets up a recurring job that runs campBinary with workDir as cwd.
func Install(campBinary, workDir, interval string) error {
	spec, err := plan.CronSpec(interval)
	if err != nil {
		return err
	}
	absCamp, err := filepath.Abs(campBinary)
	if err != nil {
		return err
	}
	absDir, err := filepath.Abs(workDir)
	if err != nil {
		return err
	}
	logPath := filepath.Join(absDir, "oracle-free-camp.log")

	switch runtime.GOOS {
	case "windows":
		return installWindows(absCamp, absDir, interval, logPath)
	default:
		return installUnixCron(absCamp, absDir, spec, logPath)
	}
}

func installUnixCron(camp, dir, cronSpec, logPath string) error {
	line := fmt.Sprintf("%s cd %s && %s >> %s 2>&1", cronSpec, shellQuote(dir), shellQuote(camp), shellQuote(logPath))
	marker := "# oracle-free-camp"
	block := fmt.Sprintf("CRON_TZ=Asia/Taipei\n%s %s\n", line, marker)

	fmt.Println("將安裝以下 crontab 區塊（CRON_TZ=Asia/Taipei）:")
	fmt.Println(block)

	existing, _ := exec.Command("crontab", "-l").CombinedOutput()
	old := string(existing)
	// strip previous marker block (simple: drop lines with marker and preceding CRON_TZ if ours)
	var kept []string
	for _, ln := range strings.Split(old, "\n") {
		if strings.Contains(ln, "oracle-free-camp") {
			continue
		}
		// drop orphan CRON_TZ=Asia/Taipei only when followed by our job — keep other CRON_TZ
		kept = append(kept, ln)
	}
	// Remove trailing empty and a lone CRON_TZ=Asia/Taipei that we re-add
	cleaned := strings.TrimRight(strings.Join(kept, "\n"), "\n")
	// If cleaned ends with our CRON_TZ alone from previous install, leave it; we rewrite block.
	var lines []string
	for _, ln := range strings.Split(cleaned, "\n") {
		if ln == "CRON_TZ=Asia/Taipei" {
			// may be shared; keep only if other jobs need it — safest: keep
			continue
		}
		if strings.TrimSpace(ln) == "" && len(lines) == 0 {
			continue
		}
		lines = append(lines, ln)
	}
	newCron := strings.TrimRight(strings.Join(lines, "\n"), "\n")
	if newCron != "" {
		newCron += "\n"
	}
	newCron += "CRON_TZ=Asia/Taipei\n" + line + " " + marker + "\n"

	tmp, err := os.CreateTemp("", "oracle-free-cron-*.txt")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.WriteString(newCron); err != nil {
		tmp.Close()
		return err
	}
	tmp.Close()

	cmd := exec.Command("crontab", tmpPath)
	out, err := cmd.CombinedOutput()
	if err != nil {
		fmt.Printf("crontab 安裝失敗: %v\n%s\n", err, out)
		fmt.Println("請手動加入 crontab:")
		fmt.Print(block)
		return err
	}
	fmt.Println("crontab 已更新。可用 crontab -l 查看。")
	fmt.Printf("日誌: %s\n", logPath)
	return nil
}

func installWindows(camp, dir, interval, logPath string) error {
	// Map interval to schtasks schedule
	var scheduleArgs []string
	switch strings.ToLower(interval) {
	case "15m", "15min":
		scheduleArgs = []string{"/SC", "MINUTE", "/MO", "15"}
	case "30m", "30min":
		scheduleArgs = []string{"/SC", "MINUTE", "/MO", "30"}
	case "1h":
		scheduleArgs = []string{"/SC", "HOURLY", "/MO", "1"}
	case "12h":
		scheduleArgs = []string{"/SC", "HOURLY", "/MO", "12"}
	case "24h":
		scheduleArgs = []string{"/SC", "DAILY", "/MO", "1"}
	default:
		return fmt.Errorf("不支援的 interval: %s", interval)
	}

	ps1 := filepath.Join(dir, "run-oracle-free-camp.ps1")
	script := fmt.Sprintf("Set-Location -LiteralPath '%s'\n& '%s' *>> '%s'\n", dir, camp, logPath)
	if err := os.WriteFile(ps1, []byte(script), 0o644); err != nil {
		return err
	}
	fmt.Printf("已寫入 PowerShell 腳本: %s\n", ps1)

	taskName := "OracleFreeCamp"
	args := []string{"/Create", "/TN", taskName, "/TR", fmt.Sprintf("powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"%s\"", ps1), "/F"}
	args = append(args, scheduleArgs...)

	fmt.Println("建議執行（系統管理員或目前使用者）:")
	fmt.Printf("  schtasks %s\n", strings.Join(quoteArgs(args), " "))
	cmd := exec.Command("schtasks", args...)
	out, err := cmd.CombinedOutput()
	fmt.Print(string(out))
	if err != nil {
		fmt.Printf("schtasks 失敗（可手動執行上方指令）: %v\n", err)
		fmt.Printf("或於「工作排程器」建立工作，動作執行: powershell -File \"%s\"\n", ps1)
		return nil // instructions written; not a hard fail
	}
	fmt.Printf("已建立排程工作: %s\n日誌: %s\n", taskName, logPath)
	return nil
}

func shellQuote(s string) string {
	if s == "" {
		return "''"
	}
	return "'" + strings.ReplaceAll(s, "'", `\'\''`) + "'"
}

func quoteArgs(args []string) []string {
	out := make([]string, len(args))
	for i, a := range args {
		if strings.ContainsAny(a, " \t\"") {
			out[i] = `"` + a + `"`
		} else {
			out[i] = a
		}
	}
	return out
}

// PrintManual shows how to schedule without modifying the system.
func PrintManual(campBinary, workDir, interval string) {
	spec, err := plan.CronSpec(interval)
	if err != nil {
		fmt.Println(err)
		return
	}
	fmt.Println("手動排程範例（Unix crontab，台北時區）:")
	fmt.Println("CRON_TZ=Asia/Taipei")
	fmt.Printf("%s cd %s && %s >> %s/oracle-free-camp.log 2>&1\n",
		spec, workDir, campBinary, workDir)
}
