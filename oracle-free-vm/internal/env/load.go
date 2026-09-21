// Package env provides a simple .env file loader (stdlib only).
package env

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// LoadDotEnv reads KEY=VALUE lines from path and sets them with
// os.Setenv only when the key is not already present in the environment.
// Missing file is a no-op (returns nil).
func LoadDotEnv(path string) error {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		val = strings.Trim(val, `"'`)
		if key == "" {
			continue
		}
		if _, exists := os.LookupEnv(key); !exists {
			_ = os.Setenv(key, val)
		}
	}
	return sc.Err()
}

// ResolveWorkDir returns the directory that holds .env / fleet-plan.txt.
// Priority: ORACLE_FREE_VM_DIR env → cwd.
func ResolveWorkDir() (string, error) {
	if d := strings.TrimSpace(os.Getenv("ORACLE_FREE_VM_DIR")); d != "" {
		return filepath.Abs(expandHome(d))
	}
	return os.Getwd()
}

// ExpandHome expands a leading ~/ to the user home directory.
func ExpandHome(p string) string {
	return expandHome(p)
}

func expandHome(p string) string {
	if p == "" {
		return p
	}
	if strings.HasPrefix(p, "~/") || p == "~" {
		home, err := os.UserHomeDir()
		if err != nil {
			return p
		}
		if p == "~" {
			return home
		}
		return filepath.Join(home, p[2:])
	}
	return p
}

// GetenvDefault returns os.Getenv(key) or def if empty.
func GetenvDefault(key, def string) string {
	v := strings.TrimSpace(os.Getenv(key))
	if v == "" {
		return def
	}
	return v
}
