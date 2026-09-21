// oracle-free-setup — interactive Traditional Chinese menus for OCI Always Free camper.
package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/Shuhimoon/tools/oracle-free-vm/internal/env"
	"github.com/Shuhimoon/tools/oracle-free-vm/internal/install"
	"github.com/Shuhimoon/tools/oracle-free-vm/internal/ociutil"
	"github.com/Shuhimoon/tools/oracle-free-vm/internal/plan"
	"github.com/Shuhimoon/tools/oracle-free-vm/internal/schedule"
)

func main() {
	os.Exit(run())
}

func run() int {
	r := bufio.NewReader(os.Stdin)
	workDir, err := env.ResolveWorkDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "無法取得工作目錄: %v\n", err)
		return 1
	}
	planPath := filepath.Join(workDir, "fleet-plan.txt")

	fmt.Println("========================================")
	fmt.Println(" Oracle Always Free 設定精靈")
	fmt.Println(" oracle-free-setup")
	fmt.Println("========================================")
	fmt.Printf("工作目錄: %s\n", workDir)
	fmt.Printf("計畫檔路徑: %s\n\n", planPath)

	// 1) OCI CLI
	fmt.Println("【步驟 1】偵測 / 安裝 OCI CLI")
	if err := install.EnsureOCICLI(r); err != nil {
		fmt.Printf("警告: %v\n（可稍後手動安裝後再跑 camp）\n\n", err)
	} else {
		fmt.Println()
	}

	// Load existing plan or start empty
	p, err := plan.Load(planPath)
	if err != nil {
		p = &plan.Plan{Interval: "15m", Entries: nil}
	}

	// 2) Fleet CRUD
	fmt.Println("【步驟 2】艦隊計畫（新增 / 刪除 / 修改）")
	fmt.Printf("boot_gb 總和上限: %d GB\n", plan.MaxBootGB)
	p = fleetMenu(r, p)

	// 3) Interval
	fmt.Println("\n【步驟 3】選擇輪詢間隔")
	p.Interval = chooseInterval(r, p.Interval)

	// 4) Write plan
	if err := plan.Save(planPath, p); err != nil {
		fmt.Fprintf(os.Stderr, "寫入計畫失敗: %v\n", err)
		return 1
	}
	fmt.Printf("\n已寫入計畫: %s\n", planPath)
	fmt.Printf("  interval=%s，共 %d 台，boot 合計 %d GB\n", p.Interval, len(p.Entries), p.SumBootGB())

	// 5) Schedule
	fmt.Println("\n【步驟 4】安裝排程（執行 oracle-free-camp）")
	campPath := resolveCampBinary(r, workDir)
	if askYN(r, "是否現在安裝排程？[Y/n] ", true) {
		if err := schedule.Install(campPath, workDir, p.Interval); err != nil {
			fmt.Printf("排程安裝未完成: %v\n", err)
			schedule.PrintManual(campPath, workDir, p.Interval)
		}
	} else {
		schedule.PrintManual(campPath, workDir, p.Interval)
	}

	// 6) Print .env / config guidance
	printConfigHelp(workDir)

	// Optional: terminate online instances
	fmt.Println("\n【選用】其他功能")
	if askYN(r, "要進入「終止線上實例」選單嗎？[y/N] ", false) {
		terminateMenu(r, workDir)
	}

	fmt.Println("\n設定完成。請填好 .env 與 ~/.oci/config 後，可手動測試:")
	fmt.Printf("  %s\n", campPath)
	return 0
}

func fleetMenu(r *bufio.Reader, p *plan.Plan) *plan.Plan {
	for {
		printFleet(p)
		fmt.Println("  [1] 新增 planned instance")
		fmt.Println("  [2] 刪除")
		fmt.Println("  [3] 修改")
		fmt.Println("  [4] 完成此步驟")
		choice := prompt(r, "請選擇: ")
		switch choice {
		case "1":
			p = addEntry(r, p)
		case "2":
			p = deleteEntry(r, p)
		case "3":
			p = modifyEntry(r, p)
		case "4":
			if len(p.Entries) == 0 {
				fmt.Println("尚未有任何項目；建議至少新增一台。仍可繼續。")
				if !askYN(r, "確定不新增就離開？[y/N] ", false) {
					continue
				}
			}
			return p
		default:
			fmt.Println("無效選項")
		}
	}
}

func printFleet(p *plan.Plan) {
	fmt.Println()
	fmt.Println("目前計畫:")
	if len(p.Entries) == 0 {
		fmt.Println("  （空）")
	}
	for i, e := range p.Entries {
		extra := ""
		if e.Shape == plan.ShapeA1 {
			extra = fmt.Sprintf(" %dOCPU/%dGB", e.OCPUs, e.MemoryGB)
		}
		fmt.Printf("  %d) %s | %s%s | boot=%dGB\n", i+1, e.Name, e.Shape, extra, e.BootGB)
	}
	fmt.Printf("  boot 合計: %d / %d GB\n", p.SumBootGB(), plan.MaxBootGB)
}

func addEntry(r *bufio.Reader, p *plan.Plan) *plan.Plan {
	e, ok := promptEntry(r, plan.Entry{}, suggestName(p))
	if !ok {
		return p
	}
	if err := p.ValidateEntry(e, -1); err != nil {
		fmt.Printf("拒絕新增: %v\n", err)
		return p
	}
	p.Entries = append(p.Entries, e)
	fmt.Println("已新增。")
	return p
}

func deleteEntry(r *bufio.Reader, p *plan.Plan) *plan.Plan {
	if len(p.Entries) == 0 {
		fmt.Println("沒有可刪除的項目。")
		return p
	}
	idx := promptIndex(r, len(p.Entries), "刪除編號: ")
	if idx < 0 {
		return p
	}
	name := p.Entries[idx].Name
	p.Entries = append(p.Entries[:idx], p.Entries[idx+1:]...)
	fmt.Printf("已刪除 %s\n", name)
	return p
}

func modifyEntry(r *bufio.Reader, p *plan.Plan) *plan.Plan {
	if len(p.Entries) == 0 {
		fmt.Println("沒有可修改的項目。")
		return p
	}
	idx := promptIndex(r, len(p.Entries), "修改編號: ")
	if idx < 0 {
		return p
	}
	e, ok := promptEntry(r, p.Entries[idx], p.Entries[idx].Name)
	if !ok {
		return p
	}
	if err := p.ValidateEntry(e, idx); err != nil {
		fmt.Printf("拒絕修改: %v\n", err)
		return p
	}
	p.Entries[idx] = e
	fmt.Println("已修改。")
	return p
}

func promptEntry(r *bufio.Reader, def plan.Entry, defaultName string) (plan.Entry, bool) {
	name := promptDefault(r, "顯示名稱", defaultName)
	if name == "" {
		fmt.Println("取消。")
		return plan.Entry{}, false
	}
	fmt.Println("Shape:")
	fmt.Println("  [1] VM.Standard.E2.1.Micro（AMD Always Free）")
	fmt.Println("  [2] VM.Standard.A1.Flex（固定 2 OCPU / 12GB）")
	defShape := "1"
	if def.Shape == plan.ShapeA1 {
		defShape = "2"
	}
	sc := promptDefault(r, "選擇 shape", defShape)
	var e plan.Entry
	e.Name = name
	switch sc {
	case "2":
		e.Shape = plan.ShapeA1
		e.OCPUs = plan.A1OCPUs
		e.MemoryGB = plan.A1MemoryGB
	default:
		e.Shape = plan.ShapeMicro
	}
	defBoot := "50"
	if def.BootGB > 0 {
		defBoot = strconv.Itoa(def.BootGB)
	}
	bootStr := promptDefault(r, "boot_gb", defBoot)
	boot, err := strconv.Atoi(strings.TrimSpace(bootStr))
	if err != nil || boot <= 0 {
		fmt.Println("boot_gb 無效，取消。")
		return plan.Entry{}, false
	}
	e.BootGB = boot
	return e, true
}

func suggestName(p *plan.Plan) string {
	candidates := []string{"af-amd-50", "af-amd-100", "af-arm-2o12"}
	for _, c := range candidates {
		if p.FindIndex(c) < 0 {
			return c
		}
	}
	return fmt.Sprintf("af-instance-%d", len(p.Entries)+1)
}

func chooseInterval(r *bufio.Reader, current string) string {
	choices := plan.IntervalChoices()
	fmt.Printf("目前: %s\n", current)
	for i, c := range choices {
		fmt.Printf("  [%d] %s (%s)\n", i+1, c.Label, c.Value)
	}
	sel := promptDefault(r, "選擇", "1")
	n, err := strconv.Atoi(sel)
	if err != nil || n < 1 || n > len(choices) {
		fmt.Printf("無效，沿用 %s\n", current)
		return current
	}
	return choices[n-1].Value
}

func resolveCampBinary(r *bufio.Reader, workDir string) string {
	exe, err := os.Executable()
	beside := ""
	if err == nil {
		dir := filepath.Dir(exe)
		cand := filepath.Join(dir, "oracle-free-camp")
		if runtimeIsWindows() {
			cand = filepath.Join(dir, "oracle-free-camp.exe")
		}
		beside = cand
	}
	def := beside
	if def == "" {
		def = filepath.Join(workDir, "oracle-free-camp")
	}
	fmt.Printf("camp 二進位預設路徑（與 setup 同目錄）: %s\n", def)
	path := promptDefault(r, "oracle-free-camp 絕對路徑", def)
	abs, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	return abs
}

func runtimeIsWindows() bool {
	return runtime.GOOS == "windows"
}

func printConfigHelp(workDir string) {
	fmt.Println("\n【步驟 5】填寫 .env 與 OCI config")
	fmt.Println("----------------------------------------")
	fmt.Printf("1. 複製範例:\n   cp %s/.env.example %s/.env\n", workDir, workDir)
	fmt.Println("2. 編輯 .env，至少填:")
	fmt.Println("   OCI_COMPARTMENT_ID=ocid1....")
	fmt.Println("   OCI_SUBNET_ID=ocid1.subnet....")
	fmt.Println("   SSH_PUBLIC_KEY_FILE=~/.ssh/你的公鑰.pub")
	fmt.Println("3. 設定 ~/.oci/config [DEFAULT]:")
	fmt.Println("   [DEFAULT]")
	fmt.Println("   user=ocid1.user.oc1..REPLACE")
	fmt.Println("   fingerprint=aa:bb:cc:...")
	fmt.Println("   tenancy=ocid1.tenancy.oc1..REPLACE")
	fmt.Println("   region=ap-singapore-1")
	fmt.Println("   key_file=~/.oci/oci_api_key.pem")
	fmt.Println("4. API 私鑰 .pem 只放本機（例如 ~/.oci/），權限 600；勿放進此專案目錄。")
	fmt.Println("5. 可用環境變數 ORACLE_FREE_VM_DIR 指定 .env / fleet-plan.txt 所在目錄。")
	fmt.Println("----------------------------------------")
}

func terminateMenu(r *bufio.Reader, workDir string) {
	fmt.Println("\n⚠ 終止線上實例會刪除 VM（不可復原）。需要兩次確認。")
	if !askYN(r, "第一次確認：要繼續嗎？[y/N] ", false) {
		return
	}
	if !askYN(r, "第二次確認：真的要列出並可能終止實例？[y/N] ", false) {
		fmt.Println("已取消。")
		return
	}
	_ = env.LoadDotEnv(filepath.Join(workDir, ".env"))
	cfg, err := ociutil.LoadConfig()
	if err != nil {
		fmt.Printf("無法載入設定: %v\n", err)
		return
	}
	list, err := cfg.ListRunningAndProvisioning()
	if err != nil {
		fmt.Printf("列出實例失敗: %v\n", err)
		return
	}
	if len(list) == 0 {
		fmt.Println("沒有 RUNNING/PROVISIONING 實例。")
		return
	}
	for i, inst := range list {
		fmt.Printf("  %d) %s [%s] %s\n", i+1, inst.DisplayName, inst.LifecycleState, inst.ID)
	}
	idx := promptIndex(r, len(list), "要終止的編號（0 取消）: ")
	if idx < 0 {
		fmt.Println("已取消。")
		return
	}
	inst := list[idx]
	fmt.Printf("即將終止: %s (%s)\n", inst.DisplayName, inst.ID)
	if !askYN(r, "最後確認 terminate？[y/N] ", false) {
		fmt.Println("已取消。")
		return
	}
	if _, err := cfg.TerminateInstance(inst.ID); err != nil {
		fmt.Printf("終止失敗: %v\n", err)
		return
	}
	fmt.Println("已送出 terminate 請求。")
}

func prompt(r *bufio.Reader, msg string) string {
	fmt.Print(msg)
	line, err := r.ReadString('\n')
	if err != nil && len(strings.TrimSpace(line)) == 0 {
		fmt.Println()
		os.Exit(1)
	}
	return strings.TrimSpace(line)
}

func promptDefault(r *bufio.Reader, label, def string) string {
	if def != "" {
		fmt.Printf("%s [%s]: ", label, def)
	} else {
		fmt.Printf("%s: ", label)
	}
	line, _ := r.ReadString('\n')
	line = strings.TrimSpace(line)
	if line == "" {
		return def
	}
	return line
}

func askYN(r *bufio.Reader, msg string, defYes bool) bool {
	fmt.Print(msg)
	line, _ := r.ReadString('\n')
	line = strings.TrimSpace(strings.ToLower(line))
	if line == "" {
		return defYes
	}
	return line == "y" || line == "yes"
}

func promptIndex(r *bufio.Reader, n int, msg string) int {
	s := prompt(r, msg)
	i, err := strconv.Atoi(s)
	if err != nil || i < 1 || i > n {
		if s == "0" {
			return -1
		}
		fmt.Println("無效編號")
		return -1
	}
	return i - 1
}
