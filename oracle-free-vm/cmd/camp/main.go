// oracle-free-camp — non-interactive Always Free capacity camper (one cycle).
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/Shuhimoon/tools/oracle-free-vm/internal/env"
	"github.com/Shuhimoon/tools/oracle-free-vm/internal/ociutil"
	"github.com/Shuhimoon/tools/oracle-free-vm/internal/plan"
)

func main() {
	os.Exit(run())
}

func run() int {
	workDir, err := env.ResolveWorkDir()
	if err != nil {
		fmt.Fprintf(os.Stderr, "無法取得工作目錄: %v\n", err)
		return 2
	}
	if err := env.LoadDotEnv(filepath.Join(workDir, ".env")); err != nil {
		fmt.Fprintf(os.Stderr, "讀取 .env 失敗: %v\n", err)
		return 2
	}

	cfg, err := ociutil.LoadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		return 2
	}

	planPath := filepath.Join(workDir, "fleet-plan.txt")
	p, err := plan.Load(planPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "讀取 fleet-plan.txt 失敗 (%s): %v\n", planPath, err)
		return 2
	}
	if len(p.Entries) == 0 {
		fmt.Fprintf(os.Stderr, "fleet-plan.txt 沒有實例項目\n")
		return 2
	}

	instances, err := cfg.ListRunningAndProvisioning()
	if err != nil {
		fmt.Fprintf(os.Stderr, "AUTH/LIST failed: %v\n", err)
		return 1
	}
	byName := map[string]ociutil.Instance{}
	for _, inst := range instances {
		byName[inst.DisplayName] = inst
	}

	fmt.Printf("region=%s\n", cfg.Region)
	var successes []string
	for i, e := range p.Entries {
		cur, ok := byName[e.Name]
		if ok && (cur.LifecycleState == "RUNNING" || cur.LifecycleState == "PROVISIONING") {
			fmt.Printf("%s: already %s (skip)\n", e.Name, cur.LifecycleState)
			continue
		}
		fmt.Printf("%s: missing — trying create…\n", e.Name)
		res := cfg.CreateInstance(e)
		if res.OK {
			fmt.Printf("%s: OK — %s\n", e.Name, res.Reason)
			successes = append(successes, e.Name)
		} else {
			fmt.Printf("%s: FAIL — %s\n", e.Name, res.Reason)
		}
		if i < len(p.Entries)-1 {
			ociutil.SleepBetweenCreates()
		}
	}

	if len(successes) > 0 {
		fmt.Printf("NOTIFY: created %s\n", joinComma(successes))
		return 0
	}
	fmt.Println("quiet: no new success")
	return 0
}

func joinComma(ss []string) string {
	out := ""
	for i, s := range ss {
		if i > 0 {
			out += ", "
		}
		out += s
	}
	return out
}
