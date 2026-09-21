// Package ociutil wraps the OCI CLI (never embeds keys).
package ociutil

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/Shuhimoon/tools/oracle-free-vm/internal/env"
	"github.com/Shuhimoon/tools/oracle-free-vm/internal/plan"
)

// Config holds runtime OCI settings from environment.
type Config struct {
	Region             string
	Profile            string
	CompartmentID      string
	SubnetID           string
	AvailabilityDomain string
	SSHPublicKeyFile   string
	ImageAMD           string
	ImageARM           string
}

// LoadConfig reads required/optional env vars (after .env is loaded).
func LoadConfig() (*Config, error) {
	c := &Config{
		Region:             env.GetenvDefault("OCI_REGION", "ap-singapore-1"),
		Profile:            env.GetenvDefault("OCI_CLI_PROFILE", "DEFAULT"),
		CompartmentID:      strings.TrimSpace(os.Getenv("OCI_COMPARTMENT_ID")),
		SubnetID:           strings.TrimSpace(os.Getenv("OCI_SUBNET_ID")),
		AvailabilityDomain: strings.TrimSpace(os.Getenv("OCI_AVAILABILITY_DOMAIN")),
		SSHPublicKeyFile:   env.ExpandHome(strings.TrimSpace(os.Getenv("SSH_PUBLIC_KEY_FILE"))),
		ImageAMD:           strings.TrimSpace(os.Getenv("OCI_IMAGE_AMD")),
		ImageARM:           strings.TrimSpace(os.Getenv("OCI_IMAGE_ARM")),
	}
	var missing []string
	if c.CompartmentID == "" {
		missing = append(missing, "OCI_COMPARTMENT_ID")
	}
	if c.SubnetID == "" {
		missing = append(missing, "OCI_SUBNET_ID")
	}
	if c.SSHPublicKeyFile == "" {
		missing = append(missing, "SSH_PUBLIC_KEY_FILE")
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("缺少環境變數: %s（請複製 .env.example 為 .env）", strings.Join(missing, ", "))
	}
	return c, nil
}

// Run executes `oci` with region/profile/json and returns stdout, stderr, exit code.
func (c *Config) Run(args ...string) (stdout, stderr string, code int) {
	full := append([]string{}, args...)
	full = append(full, "--region", c.Region, "--profile", c.Profile, "--output", "json")
	cmd := exec.Command("oci", full...)
	var outBuf, errBuf strings.Builder
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	err := cmd.Run()
	code = 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			code = 1
			if errBuf.Len() == 0 {
				errBuf.WriteString(err.Error())
			}
		}
	}
	return outBuf.String(), errBuf.String(), code
}

// RunJSON runs oci and unmarshals JSON stdout into v (expects {"data":...} or raw).
func (c *Config) RunJSON(args ...string) (json.RawMessage, error) {
	out, errStr, code := c.Run(args...)
	if code != 0 {
		msg := strings.TrimSpace(errStr)
		if msg == "" {
			msg = strings.TrimSpace(out)
		}
		if msg == "" {
			msg = fmt.Sprintf("oci failed: %v", args)
		}
		return nil, fmt.Errorf("%s", msg)
	}
	out = strings.TrimSpace(out)
	if out == "" {
		return json.RawMessage("{}"), nil
	}
	return json.RawMessage(out), nil
}

// dataField extracts the "data" array/object from OCI CLI JSON.
func dataField(raw json.RawMessage) json.RawMessage {
	var wrap struct {
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(raw, &wrap); err == nil && len(wrap.Data) > 0 {
		return wrap.Data
	}
	return raw
}

// Instance is a subset of OCI instance list fields.
type Instance struct {
	DisplayName    string `json:"display-name"`
	LifecycleState string `json:"lifecycle-state"`
	ID             string `json:"id"`
}

// ListRunningAndProvisioning returns RUNNING + PROVISIONING instances.
func (c *Config) ListRunningAndProvisioning() ([]Instance, error) {
	var all []Instance
	for _, state := range []string{"RUNNING", "PROVISIONING"} {
		raw, err := c.RunJSON(
			"compute", "instance", "list",
			"--compartment-id", c.CompartmentID,
			"--lifecycle-state", state,
			"--all",
		)
		if err != nil {
			return nil, err
		}
		var list []Instance
		if err := json.Unmarshal(dataField(raw), &list); err != nil {
			return nil, fmt.Errorf("parse instance list: %w", err)
		}
		all = append(all, list...)
	}
	return all, nil
}

type imageInfo struct {
	ID          string `json:"id"`
	DisplayName string `json:"display-name"`
}

// FindUbuntuImage returns Ubuntu 24.04 Minimal free image OCID for arch.
func (c *Config) FindUbuntuImage(arch string) (string, error) {
	if arch == "x86" && c.ImageAMD != "" {
		return c.ImageAMD, nil
	}
	if arch == "aarch64" && c.ImageARM != "" {
		return c.ImageARM, nil
	}
	shape := plan.ShapeMicro
	if arch == "aarch64" {
		shape = plan.ShapeA1
	}
	raw, err := c.RunJSON(
		"compute", "image", "list",
		"--compartment-id", c.CompartmentID,
		"--operating-system", "Canonical Ubuntu",
		"--operating-system-version", "24.04",
		"--shape", shape,
		"--sort-by", "TIMECREATED",
		"--sort-order", "DESC",
		"--all",
	)
	if err != nil {
		return "", err
	}
	var imgs []imageInfo
	if err := json.Unmarshal(dataField(raw), &imgs); err != nil {
		return "", fmt.Errorf("parse images: %w", err)
	}
	var prefer []imageInfo
	for _, img := range imgs {
		name := img.DisplayName
		if strings.Contains(name, "Minimal") && strings.Contains(name, "24.04") {
			lower := strings.ToLower(name)
			if arch == "aarch64" && strings.Contains(lower, "aarch64") {
				prefer = append(prefer, img)
			} else if arch == "x86" && !strings.Contains(lower, "aarch64") {
				prefer = append(prefer, img)
			}
		}
	}
	if len(prefer) == 0 {
		for _, img := range imgs {
			name := img.DisplayName
			if !strings.Contains(name, "24.04") {
				continue
			}
			isARM := strings.Contains(strings.ToLower(name), "aarch64")
			if isARM == (arch == "aarch64") {
				prefer = append(prefer, img)
			}
		}
	}
	if len(prefer) == 0 {
		return "", fmt.Errorf("找不到 Ubuntu 24.04 免費映像 (arch=%s)", arch)
	}
	return prefer[0].ID, nil
}

// ResolveAD returns availability domain name.
func (c *Config) ResolveAD() (string, error) {
	if c.AvailabilityDomain != "" {
		return c.AvailabilityDomain, nil
	}
	raw, err := c.RunJSON(
		"iam", "availability-domain", "list",
		"--compartment-id", c.CompartmentID,
	)
	if err != nil {
		return "", err
	}
	var ads []struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal(dataField(raw), &ads); err != nil {
		return "", err
	}
	if len(ads) == 0 {
		return "", fmt.Errorf("找不到 availability domain")
	}
	c.AvailabilityDomain = ads[0].Name
	return c.AvailabilityDomain, nil
}

// CreateResult is the outcome of a launch attempt.
type CreateResult struct {
	OK     bool
	Reason string
}

// CreateInstance launches one instance via OCI CLI.
func (c *Config) CreateInstance(e plan.Entry) CreateResult {
	sshPath := c.SSHPublicKeyFile
	if !fileExists(sshPath) {
		return CreateResult{false, fmt.Sprintf("SSH 公鑰不存在: %s", sshPath)}
	}
	imageID, err := c.FindUbuntuImage(e.Arch())
	if err != nil {
		return CreateResult{false, err.Error()}
	}
	ad, err := c.ResolveAD()
	if err != nil {
		return CreateResult{false, err.Error()}
	}
	args := []string{
		"compute", "instance", "launch",
		"--compartment-id", c.CompartmentID,
		"--availability-domain", ad,
		"--display-name", e.Name,
		"--shape", e.Shape,
		"--subnet-id", c.SubnetID,
		"--image-id", imageID,
		"--assign-public-ip", "true",
		"--ssh-authorized-keys-file", sshPath,
		"--boot-volume-size-in-gbs", fmt.Sprintf("%d", e.BootGB),
		"--wait-for-state", "RUNNING",
		"--wait-for-state", "TERMINATED",
		"--max-wait-seconds", "120",
	}
	if e.Shape == plan.ShapeA1 {
		shapeCfg, _ := json.Marshal(map[string]interface{}{
			"ocpus":       e.OCPUs,
			"memoryInGBs": e.MemoryGB,
		})
		args = append(args, "--shape-config", string(shapeCfg))
	}
	out, errStr, code := c.Run(args...)
	combined := errStr + "\n" + out
	if code == 0 {
		return CreateResult{true, "created/running"}
	}
	low := strings.ToLower(combined)
	if strings.Contains(low, "out of host capacity") || strings.Contains(low, "out of capacity") {
		return CreateResult{false, "Out of host capacity"}
	}
	if strings.Contains(low, "too many requests") || strings.Contains(combined, "429") {
		return CreateResult{false, "TooManyRequests (429)"}
	}
	lines := strings.Split(strings.TrimSpace(combined), "\n")
	msg := "create failed"
	for i := len(lines) - 1; i >= 0; i-- {
		if s := strings.TrimSpace(lines[i]); s != "" {
			if len(s) > 300 {
				s = s[:300]
			}
			msg = s
			break
		}
	}
	return CreateResult{false, msg}
}

// TerminateInstance calls oci compute instance terminate.
func (c *Config) TerminateInstance(instanceID string) (string, error) {
	out, errStr, code := c.Run(
		"compute", "instance", "terminate",
		"--instance-id", instanceID,
		"--force",
		"--preserve-boot-volume", "false",
	)
	if code != 0 {
		msg := strings.TrimSpace(errStr)
		if msg == "" {
			msg = strings.TrimSpace(out)
		}
		return "", fmt.Errorf("%s", msg)
	}
	return strings.TrimSpace(out), nil
}

// SleepBetweenCreates pauses briefly to reduce 429s.
func SleepBetweenCreates() {
	time.Sleep(2 * time.Second)
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// AbsPath is a small helper for schedule install.
func AbsPath(p string) (string, error) {
	if filepath.IsAbs(p) {
		return p, nil
	}
	return filepath.Abs(p)
}
