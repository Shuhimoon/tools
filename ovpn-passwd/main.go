// ovpn-passwd：VPN 帳號密碼（PBKDF2-SHA256）與 TOTP 驗證
// 密碼從 stdin / OpenVPN via-file 讀入，不放在命令列參數裡。
package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"strings"
	"time"
	"unicode"

	qrcode "github.com/skip2/go-qrcode"
)

const (
	algo       = "pbkdf2-sha256"
	iterations = 210000
	keyLen     = 32
	saltLen    = 16
	totpPeriod = 30
	totpDigits = 6
	issuer     = "OpenVPN"
)

func usage() {
	fmt.Fprintf(os.Stderr, `用法:
  ovpn-passwd auth     <users.db> <credfile>  OpenVPN 驗證（密碼+OTP）
  ovpn-passwd set      <users.db> <帳號>      新增或更新密碼（stdin）；沒有 OTP 會新建
  ovpn-passwd del      <users.db> <帳號>
  ovpn-passwd exists   <users.db> <帳號>
  ovpn-passwd list     <users.db>
  ovpn-passwd otp-new  <users.db> <帳號>      重設 OTP 並顯示綁定資訊
  ovpn-passwd otp-show <users.db> <帳號>      再顯示一次 OTP 綁定資訊
`)
	os.Exit(2)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "auth":
		if len(os.Args) != 4 {
			usage()
		}
		if err := cmdAuth(os.Args[2], os.Args[3]); err != nil {
			os.Exit(1)
		}
	case "set":
		if len(os.Args) != 4 {
			usage()
		}
		if err := cmdSet(os.Args[2], os.Args[3]); err != nil {
			fail(err)
		}
	case "del":
		if len(os.Args) != 4 {
			usage()
		}
		if err := cmdDel(os.Args[2], os.Args[3]); err != nil {
			fail(err)
		}
	case "exists":
		if len(os.Args) != 4 {
			usage()
		}
		if !userExists(os.Args[2], os.Args[3]) {
			os.Exit(1)
		}
	case "list":
		if len(os.Args) != 3 {
			usage()
		}
		if err := cmdList(os.Args[2]); err != nil {
			fail(err)
		}
	case "otp-new":
		if len(os.Args) != 4 {
			usage()
		}
		if err := cmdOtpNew(os.Args[2], os.Args[3]); err != nil {
			fail(err)
		}
	case "otp-show":
		if len(os.Args) != 4 {
			usage()
		}
		if err := cmdOtpShow(os.Args[2], os.Args[3]); err != nil {
			fail(err)
		}
	default:
		usage()
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

type record struct {
	user string
	line string
}

func parseLine(line string) (user string, iter int, salt, key []byte, totp string, ok bool) {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") {
		return
	}
	parts := strings.Split(line, ":")
	if len(parts) < 5 || parts[1] != algo {
		return
	}
	user = parts[0]
	if _, err := fmt.Sscanf(parts[2], "%d", &iter); err != nil || iter < 1 {
		return
	}
	var err error
	salt, err = hex.DecodeString(parts[3])
	if err != nil {
		return
	}
	key, err = hex.DecodeString(parts[4])
	if err != nil {
		return
	}
	if len(parts) >= 6 {
		totp = parts[5]
	}
	ok = user != ""
	return
}

func hashPassword(password string, salt []byte, iter int) ([]byte, error) {
	return pbkdf2.Key(sha256.New, password, salt, iter, keyLen)
}

func encodeRecord(user, password, totpSecret string) (string, error) {
	salt := make([]byte, saltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key, err := hashPassword(password, salt, iterations)
	if err != nil {
		return "", err
	}
	if totpSecret == "" {
		totpSecret, err = newTOTPSecret()
		if err != nil {
			return "", err
		}
	}
	return fmt.Sprintf("%s:%s:%d:%s:%s:%s",
		user, algo, iterations,
		hex.EncodeToString(salt), hex.EncodeToString(key), totpSecret), nil
}

func replaceTOTP(line, totpSecret string) (string, error) {
	user, iter, salt, key, _, ok := parseLine(line)
	if !ok {
		return "", fmt.Errorf("帳號資料損壞")
	}
	return fmt.Sprintf("%s:%s:%d:%s:%s:%s",
		user, algo, iter,
		hex.EncodeToString(salt), hex.EncodeToString(key), totpSecret), nil
}

func verifyPassword(password string, iter int, salt, key []byte) bool {
	got, err := hashPassword(password, salt, iter)
	if err != nil || len(got) != len(key) {
		return false
	}
	return subtle.ConstantTimeCompare(got, key) == 1
}

func newTOTPSecret() (string, error) {
	raw := make([]byte, 20)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(raw), nil
}

func decodeTOTPSecret(s string) ([]byte, error) {
	s = strings.ToUpper(strings.ReplaceAll(s, " ", ""))
	if s == "" {
		return nil, fmt.Errorf("empty totp")
	}
	if m := len(s) % 8; m != 0 {
		s += strings.Repeat("=", 8-m)
	}
	return base32.StdEncoding.DecodeString(s)
}

func hotp(secret []byte, counter uint64) uint32 {
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], counter)
	mac := hmac.New(sha1.New, secret)
	_, _ = mac.Write(buf[:])
	sum := mac.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	code := binary.BigEndian.Uint32(sum[off:off+4]) & 0x7fffffff
	mod := uint32(1)
	for i := 0; i < totpDigits; i++ {
		mod *= 10
	}
	return code % mod
}

func totpAt(secret []byte, t time.Time) string {
	return fmt.Sprintf("%06d", hotp(secret, uint64(t.Unix()/totpPeriod)))
}

func verifyTOTP(secretB32, otp string, now time.Time) bool {
	if !isNDigits(otp, totpDigits) {
		return false
	}
	sec, err := decodeTOTPSecret(secretB32)
	if err != nil {
		return false
	}
	for _, d := range []int64{-1, 0, 1} {
		want := totpAt(sec, now.Add(time.Duration(d)*totpPeriod*time.Second))
		if subtle.ConstantTimeCompare([]byte(want), []byte(otp)) == 1 {
			return true
		}
	}
	return false
}

func isNDigits(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, r := range s {
		if !unicode.IsDigit(r) {
			return false
		}
	}
	return true
}

func splitPassOTP(raw string) (pass, otp string) {
	raw = strings.TrimSpace(raw)
	for _, sep := range []string{" ", ":", "/", ","} {
		i := strings.LastIndex(raw, sep)
		if i < 0 {
			continue
		}
		left, right := raw[:i], raw[i+1:]
		if isNDigits(right, totpDigits) {
			return left, right
		}
	}
	if len(raw) > totpDigits && isNDigits(raw[len(raw)-totpDigits:], totpDigits) {
		return raw[:len(raw)-totpDigits], raw[len(raw)-totpDigits:]
	}
	return raw, ""
}

func group4(s string) string {
	var b strings.Builder
	for i, r := range s {
		if i > 0 && i%4 == 0 {
			b.WriteByte(' ')
		}
		b.WriteRune(r)
	}
	return b.String()
}

func otpauthURI(user, secret string) string {
	u := url.URL{
		Scheme: "otpauth",
		Host:   "totp",
		Path:   "/" + issuer + ":" + user,
	}
	q := url.Values{}
	q.Set("secret", secret)
	q.Set("issuer", issuer)
	q.Set("algorithm", "SHA1")
	q.Set("digits", fmt.Sprintf("%d", totpDigits))
	q.Set("period", fmt.Sprintf("%d", totpPeriod))
	u.RawQuery = q.Encode()
	return u.String()
}

func printOTPSetup(user, secret string) {
	uri := otpauthURI(user, secret)
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "======== 請設定 OTP（驗證器 App）========")
	fmt.Fprintf(os.Stderr, "帳號 : %s\n", user)
	fmt.Fprintf(os.Stderr, "金鑰 : %s\n", group4(secret))
	fmt.Fprintf(os.Stderr, "URI  : %s\n", uri)
	if qr, err := qrcode.New(uri, qrcode.Medium); err == nil {
		fmt.Fprintln(os.Stderr)
		fmt.Fprint(os.Stderr, qr.ToSmallString(false))
	}
	fmt.Fprintln(os.Stderr, "請用 Google Authenticator / Authy / 1Password 掃描 QR 或輸入金鑰。")
	fmt.Fprintln(os.Stderr, "連線時密碼欄請輸入：登入密碼 + 6 碼 OTP")
	fmt.Fprintln(os.Stderr, "  例：密碼 hello12、OTP 123456 → hello12123456 或 hello12 123456")
	fmt.Fprintln(os.Stderr, "==========================================")
}

func readDB(path string) ([]record, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()
	var out []record
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		user, _, _, _, _, ok := parseLine(line)
		if !ok {
			if strings.HasPrefix(line, "#") {
				out = append(out, record{line: line})
			}
			continue
		}
		out = append(out, record{user: user, line: line})
	}
	return out, sc.Err()
}

func writeDB(path string, recs []record) error {
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o640)
	if err != nil {
		return err
	}
	for _, r := range recs {
		if _, err := fmt.Fprintln(f, r.line); err != nil {
			f.Close()
			os.Remove(tmp)
			return err
		}
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

func readPasswordStdin() (string, error) {
	sc := bufio.NewScanner(os.Stdin)
	if !sc.Scan() {
		if err := sc.Err(); err != nil {
			return "", err
		}
		return "", fmt.Errorf("沒有讀到密碼")
	}
	return strings.TrimRight(sc.Text(), "\r"), nil
}

func findUser(recs []record, user string) int {
	for i, r := range recs {
		if r.user == user {
			return i
		}
	}
	return -1
}

func cmdSet(db, user string) error {
	pass, err := readPasswordStdin()
	if err != nil {
		return err
	}
	if len(pass) < 6 {
		return fmt.Errorf("密碼至少 6 個字")
	}
	recs, err := readDB(db)
	if err != nil {
		return err
	}
	totpSecret := ""
	newOTP := true
	if i := findUser(recs, user); i >= 0 {
		_, _, _, _, existing, ok := parseLine(recs[i].line)
		if ok && existing != "" {
			totpSecret = existing
			newOTP = false
		}
	}
	line, err := encodeRecord(user, pass, totpSecret)
	if err != nil {
		return err
	}
	_, _, _, _, totpSecret, _ = parseLine(line)
	if i := findUser(recs, user); i >= 0 {
		recs[i] = record{user: user, line: line}
	} else {
		recs = append(recs, record{user: user, line: line})
	}
	if err := writeDB(db, recs); err != nil {
		return err
	}
	if newOTP {
		printOTPSetup(user, totpSecret)
	}
	return nil
}

func cmdDel(db, user string) error {
	recs, err := readDB(db)
	if err != nil {
		return err
	}
	out := recs[:0]
	found := false
	for _, r := range recs {
		if r.user == user {
			found = true
			continue
		}
		out = append(out, r)
	}
	if !found {
		return fmt.Errorf("沒有這個使用者：%s", user)
	}
	return writeDB(db, out)
}

func userExists(db, user string) bool {
	recs, err := readDB(db)
	if err != nil {
		return false
	}
	return findUser(recs, user) >= 0
}

func cmdList(db string) error {
	recs, err := readDB(db)
	if err != nil {
		return err
	}
	n := 0
	for _, r := range recs {
		if r.user == "" {
			continue
		}
		_, _, _, _, totp, _ := parseLine(r.line)
		flag := "OTP未設定"
		if totp != "" {
			flag = "OTP已設定"
		}
		fmt.Printf("%-20s %s\n", r.user, flag)
		n++
	}
	if n == 0 {
		fmt.Fprintln(os.Stderr, "（尚無使用者）")
	}
	return nil
}

func cmdOtpNew(db, user string) error {
	recs, err := readDB(db)
	if err != nil {
		return err
	}
	i := findUser(recs, user)
	if i < 0 {
		return fmt.Errorf("沒有這個使用者：%s", user)
	}
	secret, err := newTOTPSecret()
	if err != nil {
		return err
	}
	line, err := replaceTOTP(recs[i].line, secret)
	if err != nil {
		return err
	}
	recs[i].line = line
	if err := writeDB(db, recs); err != nil {
		return err
	}
	printOTPSetup(user, secret)
	return nil
}

func cmdOtpShow(db, user string) error {
	recs, err := readDB(db)
	if err != nil {
		return err
	}
	i := findUser(recs, user)
	if i < 0 {
		return fmt.Errorf("沒有這個使用者：%s", user)
	}
	_, _, _, _, totp, ok := parseLine(recs[i].line)
	if !ok || totp == "" {
		return fmt.Errorf("%s 尚未設定 OTP，請用 otp-new", user)
	}
	printOTPSetup(user, totp)
	return nil
}

func cmdAuth(db, credFile string) error {
	f, err := os.Open(credFile)
	if err != nil {
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	var user, raw string
	if sc.Scan() {
		user = strings.TrimRight(sc.Text(), "\r")
	}
	if sc.Scan() {
		raw = strings.TrimRight(sc.Text(), "\r")
	}
	if user == "" || raw == "" {
		return fmt.Errorf("cred")
	}
	pass, otp := splitPassOTP(raw)
	recs, err := readDB(db)
	if err != nil {
		return err
	}
	i := findUser(recs, user)
	if i < 0 {
		return fmt.Errorf("auth")
	}
	_, iter, salt, key, totp, ok := parseLine(recs[i].line)
	if !ok || !verifyPassword(pass, iter, salt, key) {
		return fmt.Errorf("auth")
	}
	if totp != "" && !verifyTOTP(totp, otp, time.Now()) {
		return fmt.Errorf("auth")
	}
	return nil
}
