#!/bin/bash
# hedefteknolojibilisim.com — sunucu tarafı otomatik yayın (Alastyr cPanel, LiteSpeed; cron her dakika + anlık tetik).
#
# Anlık yayın: ops/release.mjs gönderimden hemen sonra api/yayin.php'ye POST eder; o da bu betiği (TETIK=1, $OPS/ortam'daki
#   ayarlarla) arka planda başlatır. Betik çalışıyorsa $OPS/TETIK bayrağı kalır: kilidi alan çalışma bayrağı tüketir
#   (uzağa zaten bakacak), çalışma sürerken yeni bayrak gelirse çıkışta TEK bir tur daha yapar. Tetik yalnız "şimdi bak"
#   demektir; neyin kurulacağına aşağıdaki imza/SHA256 denetimleri karar verir. Cron (her dakika) yedektir.
#   İşi olmayan tetik deploy.log'a yazmaz (yalnız $OPS/tetik.sayac); $OPS/ortam'ı yalnız cron çalışması yazar.
# Durdurma (Dosya Yöneticisi'nden boş dosya): $OPS/DURDUR → cron da tetik de hiçbir şey yapmaz (yalnız Terminal'den
#   --geri-al çalışır) · $OPS/TETIK-KAPALI → yalnız anlık tetik kapalı, cron sürer.
#
# Akış: açık yayın deposundaki (akaresocial/hedefteknoloji-yayin) dalın son commit'i → tar.gz indir → boyut/ad
#   denetimi → AÇMADAN önce yalnız SHA256SUMS + imzası çıkarılır: İMZA (bu dosyaya gömülü açık anahtar) ve arşivdeki
#   dosya kümesi = imzalı liste → tam açma → her dosyanın SHA256'sı → sürüm numarası geri gidemez, kanal doğru →
#   kapı (_ops/enabled) ve plan.txt → public_html'in anlık görüntüsü + yer değiştirme (rsync yok; aynı disk, saniyenin
#   altında) → canlı test (_ops/urls.txt) → hata varsa otomatik geri dönüş.
#
# Yalnız kendi kurduğu kök girdileri ($OPS/yonetilen.txt) taşır; web köküne sonradan konan yabancı girdiler yerinde
# kalır. İlk kurulumda (liste yokken) korunanlar dışındaki her şey taşınır; o anlık görüntü kalıcıdır (.keep).
# Yarıda kalan kurulum ($OPS/kurulum-suruyor) sonraki çalışmanın başında geri alınır.
#
# Şifre/anahtar tutmaz; depo herkese açık. Depoya yazabilen biri, özel imza anahtarı (yalnız ajansın Mac'inde) olmadan
# sunucuda hiçbir şey kuramaz ve çalıştıramaz. Betik kendini yalnız imzası doğrulanmış paketten günceller.
#
# Ayar (ortam değişkenleri; varsayılanlar kanala göre):
#   CHANNEL   live | staging
#   WEBROOT   live: $HOME/public_html              staging: $HOME/yeni.hedefteknolojibilisim.com
#   SITE_URL  live: https://hedefteknolojibilisim.com   staging: https://yeni.hedefteknolojibilisim.com
#   OPS       live: $HOME/hedefteknoloji-ops       staging: $HOME/hedefteknoloji-ops-staging  (günlük, durum, anlık görüntü)
#   BACKUPS   live: $HOME/hedefteknoloji-yedek     staging: $HOME/hedefteknoloji-yedek-staging (ilk kurulumdan önceki tam yedek)
#   REPO=akaresocial/hedefteknoloji-yayin  BRANCH (live: main, staging: staging)  KEEP=3
#   MAX_DL_MB=300  MAX_UNPACK_MB=400  MAX_ENTRIES=20000  RESERVE_MB=100  LOCK_STUCK_MIN=30  BACKUP_STUCK_MIN=240
#   GIT_TIMEOUT=60
#   RESOLVE_IP  (isteğe bağlı) sunucu kendi genel IP'sine ulaşamıyorsa canlı test isteklerini bu IP'ye sabitle (ör. 127.0.0.1)
# Elle geri dönüş: cPanel → Dosya Yöneticisi → $OPS içinde GERI-AL adlı boş dosya (sonraki cron, dosya son kurulumdan
#   SONRA oluşturulmuşsa bir adım geri alır; içine sha yazılırsa yalnız canlı sürüm oysa)
#   ya da Terminal: bash ~/hedefteknoloji-ops/deploy.sh --geri-al   (tekrarı: --geri-al --tekrar · tek seferlik: --geri-al <sha>)
# Test kancaları (yalnız ops/test-deploy.sh): TEST_SHA, TEST_TARBALL, TEST_DL_URL, TEST_RELEASE_DIR, TEST_LOCK_SLEEP,
#   TEST_MOVE_SLEEP, TEST_NO_FLOCK (flock olsa da mkdir kilidi), PAUSE, SETTLE
# Tetik (api/yayin.php koyar): TETIK=1 (kaynak: tetik — günlük ve status.json), TETIK_EK_TUR=1 (çıkıştaki ek tur)
set -u
set -o pipefail
umask 022
export LC_ALL=C
PATH="$PATH:/usr/local/bin:/usr/local/cpanel/bin:/usr/local/cpanel/3rdparty/bin"

MODE="${1:-}"
MARG="${2:-}"
# betiğin mutlak yolu: ek tur (tetik) ve api/yayin.php ($OPS/ortam → BETIK) bununla başlatır
SELF="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)/$(basename "$0")"
T0_RUN=$(date +%s)
KAYNAK=cron; [ "${TETIK:-}" = 1 ] && KAYNAK=tetik
# Terminal'den elle çalıştırma: ortamı cron'unki değildir (RESOLVE_IP …) → tetik ayarını ($OPS/ortam) yazmaz, ek tur yapmaz
INTERAKTIF=0; if [ -t 0 ] || [ -t 1 ]; then INTERAKTIF=1; fi
CHANNEL="${CHANNEL:-live}"
case "$CHANNEL" in
  live) d_branch=main; d_url=https://hedefteknolojibilisim.com; d_root="$HOME/public_html"; d_ops="$HOME/hedefteknoloji-ops"; d_bk="$HOME/hedefteknoloji-yedek" ;;
  staging) d_branch=staging; d_url=https://yeni.hedefteknolojibilisim.com; d_root="$HOME/yeni.hedefteknolojibilisim.com"; d_ops="$HOME/hedefteknoloji-ops-staging"; d_bk="$HOME/hedefteknoloji-yedek-staging" ;;
  *) echo "CHANNEL yalnız live ya da staging olabilir" >&2; exit 2 ;;
esac
REPO="${REPO:-akaresocial/hedefteknoloji-yayin}"
BRANCH="${BRANCH:-$d_branch}"
SITE_URL="${SITE_URL:-$d_url}"; SITE_URL="${SITE_URL%/}"
WEBROOT="${WEBROOT:-$d_root}"; WEBROOT="${WEBROOT%/}"
OPS="${OPS:-$d_ops}"; OPS="${OPS%/}"
BACKUPS="${BACKUPS:-$d_bk}"; BACKUPS="${BACKUPS%/}"
KEEP="${KEEP:-3}"
MIN_FILES="${MIN_FILES:-100}"
MAX_DL_MB="${MAX_DL_MB:-300}"           # indirilen arşiv üst sınırı (curl sürümünden bağımsız; aşan sürüm reddedilir)
MAX_UNPACK_MB="${MAX_UNPACK_MB:-400}"   # açılmış paket üst sınırı (sıkıştırma bombası diski dolduramaz)
MAX_ENTRIES="${MAX_ENTRIES:-20000}"     # arşivdeki girdi sayısı üst sınırı (inode kotası)
RESERVE_MB="${RESERVE_MB:-100}"         # yedek/kurulumdan sonra hesapta boş kalması gereken alan (posta, PHP oturumları)
LOCK_STUCK_MIN="${LOCK_STUCK_MIN:-30}"  # kilidi bundan uzun tutan çalışma takılmış sayılır, durdurulur
BACKUP_STUCK_MIN="${BACKUP_STUCK_MIN:-240}" # ilk kurulum yedeği aşamasının sınırı (büyük web kökü + LVE IO sınırı yavaştır)
GIT_TIMEOUT="${GIT_TIMEOUT:-60}"
PAUSE="${PAUSE:-0.2}"   # canlı testte istekler arası bekleme (sunucuya kibar, sıralı)
SETTLE="${SETTLE:-3}"   # kurulumdan sonra ilk teste kadar bekleme
UA="HedefYayin/1.0 (deploy.sh)"
TAB=$(printf '\t')
NL='
'

# ── güvenilen açık anahtar(lar) — ops/release.pub.pem ile aynı olmalı (node ops/release.mjs --sync-pubkey) ──────────
# Birden fazla blok olabilir (anahtar yenileme dönemi); imza bunlardan biriyle doğrulanırsa geçerlidir.
pubkeys() {
cat <<'HEDEF_ACIK_ANAHTAR'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAznb1oSf7gApNu5l8z+Xd
U6eltmfHzAbi5y8MqShf8ToP/SODCj7m2j3J2lx8BY13C8yRxA2m/R2a0SB1i6H4
8KEyr9ap9A4CEmkY6HjHuV7MM/m24heGlQShJlTtx5jTcFL5fV1xVf5QYUgzMQv/
LolY2Wcj72DEIaNXWOC5zazdufdzLMDO3kzu+QVIrCKqUf/+hBXmY4kCJUwhPg9W
d3BGSb6mn/PrX0rG40WqGT/kDTr25c0jUyxQMb42fUFqlbGeo7lMwEanxcjK2vXp
erbOaLxNHzDuP8HwOve0vcLAT0QH+2x+XwYfXqVrXdAWh7aGTQMnoHRMPekbd9AI
dja+Q/7udapIAVSDz50YHZ3gJKC4qACBhBxjXdOA5TuQDwyPpA3c9ubR3OQB226U
uHTWVwbxehw/R66WwDZmtQX+WzYz4Yn7TSRk6MGAU/dr1EpFRFbzIOvTe1vIBImw
NOO0znMZM9NIDyWzReLYZsN37u7Vvzc0hATLPPm0f5XNAgMBAAE=
-----END PUBLIC KEY-----
HEDEF_ACIK_ANAHTAR
}

# ── yardımcılar ───────────────────────────────────────────────────────────────────────────────────────────────────
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
# Tetikli çalışmanın başlığı ilk gerçek satırdan hemen önce yazılır: işi olmayan tetik günlüğe hiç yazmaz (herkese açık uç
# nokta günlüğü döndürüp geçmişi silemez). LOG_YAZDI: bu çalışma günlüğe bir şey yazdı mı
TETIK_BASLIK=""; TETIK_YAZDI=0; LOG_YAZDI=0
baslik_yaz() { local b="$TETIK_BASLIK"; [ -n "$b" ] || return 0; TETIK_BASLIK=""; TETIK_YAZDI=1; log "$b"; }
# Denetim karakterleri (CR, ESC …) atılır: arşivden gelen bir ad terminalde satırı silip sahte satır gösteremez;
# UTF-8 Türkçe baytlar kalır
log() {
  local m
  baslik_yaz
  m=$(printf '%s' "$*" | tr -d '\000-\037\177')
  printf '[%s] [%s] %s\n' "$(ts)" "$CHANNEL" "$m" >> "$OPS/deploy.log"; printf '%s\n' "$m"
  LOG_YAZDI=1
}
# stdin → yazdırılabilir ASCII ve satır sonu dışı her bayt '?' (imzası henüz doğrulanmamış arşivdeki adlar günlüğe
# böyle girer)
ascii() { tr -c ' -~\n' '?'; }
# Aynı engel (ağ, uapi …) her dakika günlüğü doldurmasın
log_once() {
  local key="$1"; shift
  [ "$(cat "$OPS/.son-not" 2>/dev/null)" = "$key" ] && return 0
  printf '%s' "$key" > "$OPS/.son-not"
  log "$@"
}
jesc() { printf '%s' "$1" | tr -d '\000-\037\177' | sed 's/\\/\\\\/g; s/"/\\"/g'; }
status() {
  printf '{"time":"%s","channel":"%s","state":"%s","sha":"%s","release":"%s","seq":"%s","note":"%s","kaynak":"%s"}\n' \
    "$(ts)" "$CHANNEL" "$1" "${sha:-}" "$(jesc "${rid:-}")" "${seq:-}" "$(jesc "${2:-}")" "$KAYNAK" > "$OPS/status.json.tmp" &&
    mv -f "$OPS/status.json.tmp" "$OPS/status.json"
}
phys() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
in_list() { [ -f "$2" ] && grep -qxF -- "$1" "$2"; }
# Bir klasörün kök girdileri (gizliler dahil), satır başına bir ad
list_top() {
  local p
  for p in "$1"/* "$1"/.[!.]* "$1"/..?*; do exists "$p" && printf '%s\n' "${p##*/}"; done
  return 0
}
if command -v sha256sum >/dev/null 2>&1; then SHACMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHACMD="shasum -a 256"
else SHACMD=""; fi
# stdin: NUL ile ayrılmış yollar → "özet  yol" satırları
sha_list() {
  if [ -n "$SHACMD" ]; then xargs -0 -r $SHACMD; else xargs -0 -r -n 1 openssl dgst -sha256 -r | sed 's/ \*/  /'; fi
}
sha_file() { printf '%s\0' "$1" | sha_list | cut -c1-64; }
sha_stdin() { if [ -n "$SHACMD" ]; then $SHACMD | cut -c1-64; else openssl dgst -sha256 -r | cut -c1-64; fi; }
# .htaccess, cPanel'in yönettiği bloklar (MultiPHP) ve boş satırlar olmadan: cPanel bloğu değiştirse de özet aynı kalır
ht_norm() { awk '/^# .*BEGIN cPanel-generated/{s=1} !s && NF{print} /^# .*END cPanel-generated/{s=0}' "$1"; }
# $1 = klasör → "özet  göreli/yol" satırları, sıralı (kökteki .htaccess cPanel blokları olmadan; error_log'lar hariç)
tree_sums() {
  ( cd "$1" 2>/dev/null || exit 1
    find . -type f ! -name error_log ! -path ./.htaccess -print0 | sha_list | sed 's#  \./#  #'
    if [ -f .htaccess ]; then printf '%s  .htaccess\n' "$(ht_norm .htaccess | sha_stdin)"; fi
  ) | sort
}
# $1 = saniye, sonra komut → süre aşılırsa durdurulur (sunucuda timeout yoksa kabukla)
run_limited() {
  local t="$1" p w rc
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; return; fi
  "$@" &
  p=$!
  ( sleep "$t"; kill -TERM "$p" 2>/dev/null ) >/dev/null 2>&1 9>&- &
  w=$!
  wait "$p"; rc=$?
  # bekçi, sleep'iyle birlikte: yetim kalan sleep bash'in sakladığı kilit tanımlayıcısını (fd 9'un kopyası) 60 sn tutardı
  kill_tree "$w"; wait "$w" 2>/dev/null
  return "$rc"
}
uapi_bin() {
  local u
  u=$(command -v uapi 2>/dev/null || true)
  [ -n "$u" ] || { [ -x /usr/local/cpanel/bin/uapi ] && u=/usr/local/cpanel/bin/uapi; }
  [ -n "$u" ] || return 1
  printf '%s' "$u"
}
# cPanel kotası → "sınır_KB kullanılan_KB inode_sınırı kullanılan_inode" (0 = sınırsız); okunamazsa boş
quota_info() {
  local u out
  u=$(uapi_bin) || return 0
  out=$(run_limited 30 "$u" Quota get_quota_info --output=json 2>/dev/null 9>&- | tr -d '\r\n\t ')
  printf '%s' "$out" | grep -q '"status":1' || return 0
  printf '%s' "$out" | awk '
    function num(k,   m) { if (match($0, "\"" k "\":\"?[0-9.]+")) { m = substr($0, RSTART, RLENGTH); sub(/.*:"?/, "", m); return m + 0 } return -1 }
    { ml = num("megabyte_limit"); mu = num("megabytes_used"); il = num("inode_limit"); iu = num("inodes_used")
      if (mu < 0) exit
      printf "%d %d %d %d\n", (ml > 0 ? ml * 1024 : 0), mu * 1024, (il > 0 ? il : 0), (iu > 0 ? iu : 0) }'
}
# $1 = gereken KB, $2 = gereken dosya sayısı, $3 = iş adı, $4 = hedef klasör → yer (disk + cPanel kotası, RESERVE_MB
# payıyla) yetmiyorsa 1 ve neden $why'da
space_ok() {
  local need=$(( $1 + RESERVE_MB * 1024 )) d q lim used ilim iused
  why=""
  d=$(df -Pk "$4" 2>/dev/null | awk 'NR==2{print $4}')
  case "$d" in ''|*[!0-9]*) d="" ;; esac
  if [ -n "$d" ] && [ "$d" -lt "$need" ]; then
    why="$3 için yer yok: diskte $((d / 1024)) MB boş, gereken $((need / 1024)) MB ($RESERVE_MB MB pay dahil)"; return 1
  fi
  q=$(quota_info)
  [ -n "$q" ] || return 0
  read -r lim used ilim iused <<EOF
$q
EOF
  if [ "$lim" -gt 0 ] && [ $((lim - used)) -lt "$need" ]; then
    why="$3 için yer yok: cPanel kotasında $(( (lim - used) / 1024 )) MB boş, gereken $((need / 1024)) MB ($RESERVE_MB MB pay dahil)"; return 1
  fi
  if [ "$ilim" -gt 0 ] && [ $((ilim - iused)) -lt $(( $2 + 1000 )) ]; then
    why="$3 için yer yok: dosya (inode) kotasında $((ilim - iused)) boş, gereken $(( $2 + 1000 ))"; return 1
  fi
  return 0
}
# $1 = klasör → boş alan KB (disk ile cPanel kotasının küçüğü); ikisi de okunamazsa boş
free_kb() {
  local d q lim used f=""
  d=$(df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4}')
  case "$d" in ''|*[!0-9]*) ;; *) f=$d ;; esac
  q=$(quota_info)
  if [ -n "$q" ]; then
    read -r lim used _ <<EOF
$q
EOF
    if [ "$lim" -gt 0 ] && { [ -z "$f" ] || [ $((lim - used)) -lt "$f" ]; }; then f=$((lim - used)); fi
  fi
  printf '%s' "$f"
}

KEYDIR=""
LOCKDIR=""
LOCKFILE=""
LOCK_OWNED=0
SINYAL=""
RB_NOTE=""
GUARD_N=0
# İşi olmayan tetikli çalışma: günlük yerine tek satırlık sayaç "sayı son-zaman" (kilit altında yazılır)
tetik_say() {
  local n=""
  { read -r n _ < "$OPS/tetik.sayac"; } 2>/dev/null
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  { printf '%s %s\n' "$((n + 1))" "$(ts)" > "$OPS/tetik.sayac.tmp" && mv -f "$OPS/tetik.sayac.tmp" "$OPS/tetik.sayac"; } 2>/dev/null
}
on_exit() {
  local rc=$? released=0
  [ -n "$KEYDIR" ] && rm -rf "$KEYDIR"
  if [ "$LOCK_OWNED" = 1 ] && [ "$KAYNAK" = tetik ]; then
    TETIK_BASLIK=""   # bundan sonraki satır başlık açmasın
    if [ "$TETIK_YAZDI" = 1 ]; then log "kaynak: tetik — çalışma bitti (çıkış $rc, $(( $(date +%s) - T0_RUN )) sn)"; else tetik_say; fi
  fi
  # kilit klasörü yalnız hâlâ bu çalışmanınsa silinir (durdurulan çalışmanın tuzağı devralanın kilidini silmesin)
  if [ -n "$LOCKDIR" ] && [ "$(cut -d' ' -f1 "$LOCKDIR/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$LOCKDIR"; released=1; fi
  # flock: kayıt boşaltılır (kilidi bir an yoklayan api/yayin.php'ye denk gelen çalışma, bitmiş çalışmanın eski kaydını
  # "takılmış" sanmasın), sonra kilit bırakılır
  if [ "$LOCK_OWNED" = 1 ] && [ -z "$LOCKDIR" ]; then { : > "$LOCKFILE"; } 2>/dev/null; exec 9>&-; released=1; fi
  # Çalışma sürerken gelen tetik (bayrak kilit alınırken silinmişti): kilit bırakıldıktan SONRA bakılır — api/yayin.php
  # bayrağı yazıp kilide bakar; hangi sırayla olursa olsun tetik kaybolmaz. Tek ek tur (ek turda bir daha yok); sinyalle
  # durdurulan çalışma ek tur başlatmaz. Elle çalıştırma (Terminal ya da --geri-al) da başlatmaz: ek tur onun ortamını
  # (RESOLVE_IP'siz …) devralırdı — bayrak cron'a kalır (≤ 1 dk). DURDUR / TETIK-KAPALI varken de bayrak cron'a kalır.
  if [ "$released" = 1 ] && [ -z "$SINYAL" ] && [ -z "${TETIK_EK_TUR:-}" ] && [ -z "$MODE" ] && [ "$INTERAKTIF" = 0 ] &&
     [ ! -e "$OPS/DURDUR" ] && [ ! -e "$OPS/TETIK-KAPALI" ] && [ -e "$OPS/TETIK" ]; then
    rm -f "$OPS/TETIK"
    # iş yapmamış çalışma bunu da günlüğe yazmaz; ek tur iş yaparsa kendi başlığında "ek tur" yazar
    [ "$LOG_YAZDI" = 1 ] && log "tetik: çalışma sürerken yeni tetik geldi — bir tur daha"
    export TETIK=1 TETIK_EK_TUR=1
    exec "$BASH" "$SELF"
  fi
  return 0
}
trap on_exit EXIT
# Sinyal (Terminal kapandı, Ctrl-C, takılan çalışmanın durdurulması): kurulum dışında yalnız işaretlenip çıkılır (ek tur
# yok); kurulum sırasında on_signal geri alır
plain_traps() {
  trap 'SINYAL=HUP; exit 129' HUP
  trap 'SINYAL=INT; exit 130' INT
  trap 'SINYAL=TERM; exit 143' TERM
}
plain_traps

mkdir -p "$OPS" || exit 1
chmod 700 "$OPS" 2>/dev/null

# ── tek örnek: üst üste binen cron çalışmaları (flock yoksa mkdir kilidi) ──────────────────────────────────────────
# $1 = süreç → önce kendisi, sonra (önceden toplanan) alt süreçleri TERM ile durdurulur
kill_tree() {
  local kids c
  kids=$(ps -e -o pid= -o ppid= 2>/dev/null | awk -v p="$1" '$2 == p {print $1}')
  kill -TERM "$1" 2>/dev/null
  for c in $kids; do kill_tree "$c"; done
}
# $1 = "PID başlangıç [aşama]" dosyası → kilidin sahibi aşamasının sınırından (LOCK_STUCK_MIN; ilk kurulum yedeğinde
# BACKUP_STUCK_MIN) uzun sürüyorsa durdurulur (0 döner). Aşama başlarken başlangıç zamanı yenilenir (lock_phase).
lock_stuck() {
  local pid="" start="" phase="" age args lim="$LOCK_STUCK_MIN"
  { read -r pid start phase < "$1"; } 2>/dev/null
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$start" in ''|*[!0-9]*) return 1 ;; esac
  [ "$phase" = yedek ] && lim="$BACKUP_STUCK_MIN"
  age=$(( ($(date +%s) - start) / 60 ))
  [ "$age" -ge "$lim" ] || return 1
  args=$(ps -p "$pid" -o args= 2>/dev/null || true)
  case "$args" in
    *deploy.sh*)
      if [ "$phase" = yedek ]; then
        log "kilit: önceki çalışmanın ilk kurulum yedeği (PID $pid) $age dakikadır sürüyor (sınır $lim dk) — durduruluyor; yarım yedek sonraki çalışmada silinir, kendiliğinden yeniden denenmez"
        status stuck "ilk kurulum yedeği $age dk sürdü (PID $pid) ve durduruldu; kurulum yapılmadı, yedek kendiliğinden yeniden denenmez (DEPLOY.md §4.5)"
      else
        log "kilit: önceki çalışma (PID $pid) $age dakikadır sürüyor — takıldı, durduruluyor"
        status stuck "önceki çalışma $age dk takılı kaldı (PID $pid); durduruldu — sonraki çalışma yarım kalan kurulumu geri alıp devam eder"
      fi
      kill_tree "$pid"; return 0 ;;
  esac
  log_once "kilit-sahipsiz-$pid" "kilit: $age dakikadır tutuluyor ama sahibi (PID $pid) bu betik değil — elle bakın ($OPS/.kilit)"
  status stuck "kilit $age dk tutuluyor; sahibi bulunamadı — elle bakın"
  return 1
}
# $1 = aşama → kilit kaydı "PID şimdi aşama" (takılma süresi aşamanın başından ölçülür)
lock_phase() { [ -z "$LOCKFILE" ] || { printf '%s %s %s\n' "$$" "$(date +%s)" "$1" > "$LOCKFILE"; } 2>/dev/null || true; }
# kilit dolu: cron günlüğe yazar; tetikle başlatılan çalışma sessiz çıkar — api/yayin.php'nin bıraktığı bayrak (TETIK)
# kilidin sahibine kalır, kaybolan bir şey yok
kilit_dolu() { [ "$KAYNAK" = tetik ] || log "kilit: başka bir çalışma sürüyor — çıkıldı"; }
# $1 = kilit klasörü → sahibi ölüyse (ya da kayıt yok ve klasör 10 dk'dan eskiyse) 0
lock_dead() {
  local p
  p=$(cut -d' ' -f1 "$1/pid" 2>/dev/null || true)
  if [ -n "$p" ]; then ! kill -0 "$p" 2>/dev/null; return; fi
  [ -d "$1" ] && [ -n "$(find "$1" -maxdepth 0 -mmin +10 2>/dev/null)" ]
}
if [ -z "${TEST_NO_FLOCK:-}" ] && command -v flock >/dev/null 2>&1; then
  # >> : bekleyen çalışmalar dosyayı (sahibinin PID'ini) silmesin
  exec 9>> "$OPS/.kilit"
  if ! flock -n 9; then
    lock_stuck "$OPS/.kilit" || kilit_dolu
    exit 0
  fi
  LOCKFILE="$OPS/.kilit"
else
  ld="$OPS/.kilit.d"
  if ! mkdir "$ld" 2>/dev/null; then
    # takılan sahip durduruldu: kilit bu çalışmada devralınmaz (durdurulan çalışma sinyalde geri dönüş yapıyor olabilir);
    # sonraki çalışma sahibi ölü bulup devralır
    if ! lock_dead "$ld" && lock_stuck "$ld/pid"; then exit 0; fi
    # Sahipsiz kilidi devralma tek sahipli: silme kararı ikinci bir mkdir kilidi (.kilit.devral) altında, sahip YENİDEN
    # okunarak verilir. İki çalışma aynı anda "sahipsiz" görse de yalnız ilki siler; ikincisi yeni sahibin canlı kilidini
    # görür ve çıkar (yalnız "ölü gördüm → mv" dizisi, arada kilidi devralmış çalışmanın kilidini silebiliyordu).
    if lock_dead "$ld"; then
      dv="$OPS/.kilit.devral"
      if mkdir "$dv" 2>/dev/null; then
        if lock_dead "$ld"; then rm -rf "$ld"; log "kilit: sahipsiz eski kilit temizlendi"; fi
        rmdir "$dv" 2>/dev/null
      elif [ -n "$(find "$dv" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
        # devralma milisaniyeler sürer: 10 dakikalık devralma kilidi öldürülmüş bir çalışmadan kalmıştır — yalnız o
        # kaldırılır, devralma sonraki çalışmaya kalır
        rmdir "$dv" 2>/dev/null && log "kilit: yarım kalmış devralma kilidi (.kilit.devral) kaldırıldı"
      fi
    fi
    if ! mkdir "$ld" 2>/dev/null; then kilit_dolu; exit 0; fi
  fi
  LOCKDIR="$ld"
  LOCKFILE="$ld/pid"
fi
LOCK_OWNED=1
lock_phase baslangic
# günlük en fazla 1 MB (son 256 KB kalır); tetikle başlatılan çalışmaların hata çıktısı en fazla 64 KB. Kilit altında:
# kilidi alamayan çalışma, sahibi yazarken döndürüp onun satırlarını kaybettirmesin.
if [ -f "$OPS/deploy.log" ] && [ "$(wc -c < "$OPS/deploy.log" | tr -d ' ')" -gt 1048576 ]; then
  tail -c 262144 "$OPS/deploy.log" > "$OPS/deploy.log.tmp" && mv -f "$OPS/deploy.log.tmp" "$OPS/deploy.log"
fi
if [ -f "$OPS/tetik.hata" ] && [ "$(wc -c < "$OPS/tetik.hata" | tr -d ' ')" -gt 65536 ]; then
  tail -c 16384 "$OPS/tetik.hata" > "$OPS/tetik.hata.tmp" && mv -f "$OPS/tetik.hata.tmp" "$OPS/tetik.hata"
fi

# ── durdurma anahtarları (Dosya Yöneticisi'nden boş dosya; DEPLOY.md §5, §4.6) ──────────────────────────────────────
# $OPS/DURDUR: hat tamamen durur — cron da tetik de hiçbir şey yapmaz (yarım kurulum kurtarma, GERI-AL, indirme dahil);
# api/yayin.php 503 döner. Yalnız Terminal'den elle verilen --geri-al çalışır. Silinince sonraki cron kaldığı yerden sürer.
if [ -e "$OPS/DURDUR" ] && [ -z "$MODE" ]; then
  [ "$KAYNAK" = tetik ] && exit 0
  # günlüğe ve status.json'a bir kez ($OPS/.durdu işareti), her dakika değil
  if [ ! -e "$OPS/.durdu" ]; then
    : > "$OPS/.durdu"
    log "durduruldu: $OPS/DURDUR var — cron ve anlık tetik hiçbir şey yapmıyor; devam için dosyayı silin"
    status stopped "DURDUR dosyası var — hat duruyor; devam için hedefteknoloji-ops*/DURDUR'u silin (DEPLOY.md §5)"
  fi
  exit 0
fi
if [ -e "$OPS/.durdu" ] && [ -z "$MODE" ]; then
  rm -f "$OPS/.durdu"; log "devam: $OPS/DURDUR kaldırıldı — hat yeniden çalışıyor"
fi
# $OPS/TETIK-KAPALI: yalnız anlık tetik kapalı (api/yayin.php 503 döner); cron etkilenmez
if [ -e "$OPS/TETIK-KAPALI" ] && [ "$KAYNAK" = tetik ]; then exit 0; fi

# Anlık yayın tetiği: uzak sürüme bakacak çalışma bekleyen bayrağı tüketir (--geri-al bakmaz, bayrak kalır). Çalışma
# sürerken yenisi gelirse (api/yayin.php bayrağı yazar) çıkışta bir tur daha yapılır (on_exit).
[ -z "$MODE" ] && rm -f "$OPS/TETIK"
[ "$KAYNAK" = tetik ] && TETIK_BASLIK="kaynak: tetik — çalışma başladı (PID $$${TETIK_EK_TUR:+; ek tur: önceki çalışma sürerken tetik geldi})"
[ -n "${TEST_LOCK_SLEEP:-}" ] && sleep "$TEST_LOCK_SLEEP"

# ── ilk çalışmada ortam dökümü (sunucuda neler var?) ─────────────────────────────────────────────────────────────
if [ ! -f "$OPS/.doktor" ]; then
  log "doktor: bash=$BASH_VERSION kanal=$CHANNEL dal=$BRANCH web_kökü=$WEBROOT site=$SITE_URL ops=$OPS yedek=$BACKUPS"
  for t in curl tar gzip git flock timeout setsid sha256sum shasum openssl uapi mysqldump; do
    if command -v "$t" >/dev/null 2>&1; then log "doktor: $t=$(command -v "$t")"; else log "doktor: $t=YOK"; fi
  done
  command -v openssl >/dev/null 2>&1 && log "doktor: $(openssl version 2>&1 | head -1)"
  log "doktor: betik sha256=$(sha_file "$0")"
  touch "$OPS/.doktor"
fi

# ── yol güvenliği ─────────────────────────────────────────────────────────────────────────────────────────────────
if [ ! -d "$WEBROOT" ]; then log_once "webroot-yok" "HATA: web kökü yok: $WEBROOT"; status blocked "web kökü yok"; exit 1; fi
wr_phys=$(phys "$WEBROOT")
ops_phys=$(phys "$OPS")
mkdir -p "$BACKUPS" && chmod 700 "$BACKUPS" 2>/dev/null
bk_phys=$(phys "$BACKUPS")
home_phys=$(phys "$HOME")
bad_path=""
[ "$wr_phys" = "/" ] || [ "$wr_phys" = "$home_phys" ] && bad_path="web kökü ev klasörü ya da / olamaz"
case "$ops_phys/" in "$wr_phys"/*) bad_path="OPS web kökünün içinde olamaz (anlık görüntülerde wp-config.php var)" ;; esac
case "$bk_phys/" in "$wr_phys"/*) bad_path="BACKUPS web kökünün içinde olamaz" ;; esac
case "$wr_phys/" in "$ops_phys"/*) bad_path="web kökü OPS'un içinde olamaz" ;; esac
if [ -n "$bad_path" ]; then log_once "yol-$bad_path" "HATA: $bad_path"; status blocked "$bad_path"; exit 1; fi
# yarıda kalmış yedek denemesinin artıkları
rm -f "$BACKUPS"/*.partial 2>/dev/null

# ── anlık yayın tetiğinin ayarı: cron çalışmasının ortamı, web kökü dışında ($OPS/ortam; api/yayin.php okur) ─────────
# Tetik deploy.sh'yi yalnız bu dosyadaki (beyaz liste, sıkı düzen) değerlerle başlatır; cron'daki ayar (RESOLVE_IP …)
# tetikli çalışmaya da geçer. Güvenli olmayan değer varsa dosya yazılmaz (varsa silinir): tetik 503 döner, cron etkilenmez.
# Yalnız cron yazar: Terminal'den elle çalıştırma (RESOLVE_IP'siz ortam) ve tetikli çalışma yazmaz — cron satırları
# silinip ortam da silinince onu yeniden yazan bir şey kalmaz.
ORTAM_KEYS="CHANNEL SITE_URL WEBROOT OPS BACKUPS BRANCH REPO HOME RESOLVE_IP KEEP MIN_FILES MAX_DL_MB MAX_UNPACK_MB MAX_ENTRIES RESERVE_MB LOCK_STUCK_MIN BACKUP_STUCK_MIN GIT_TIMEOUT"
safe_val() { case "$1" in ''|*[!A-Za-z0-9_./:@+-]*) return 1 ;; esac; return 0; }
write_ortam() {
  local k v bad="" body
  body="# deploy.sh'nin cron çalışması yazar; api/yayin.php (anlık yayın tetiği) okur — elle düzenlemeyin$NL"
  for k in $ORTAM_KEYS; do
    eval "v=\${$k:-}"
    [ -z "$v" ] && [ "$k" = RESOLVE_IP ] && continue
    if safe_val "$v"; then body="$body$k=$v$NL"; else bad="$bad $k"; fi
  done
  # tetik yalnız bu ops klasöründeki deploy.sh'yi başlatır (api/yayin.php de denetler)
  if safe_val "$SELF" && [ "$(dirname "$SELF")" = "$ops_phys" ]; then body="${body}BETIK=$SELF$NL"; else bad="$bad BETIK"; fi
  if [ -n "$bad" ]; then
    if [ -e "$OPS/ortam" ] || [ ! -e "$OPS/.ortam-uyari" ]; then
      rm -f "$OPS/ortam"; : > "$OPS/.ortam-uyari"
      log "tetik: $OPS/ortam yazılmadı —$bad: değer yalnız A-Z a-z 0-9 _ . / : @ + - içerebilir, betik $OPS/deploy.sh olmalı (şu an $SELF); anlık tetik kapalı (503), cron etkilenmez"
    fi
    return 0
  fi
  rm -f "$OPS/.ortam-uyari"
  [ "$(cat "$OPS/ortam" 2>/dev/null)$NL" = "$body" ] && return 0
  { printf '%s' "$body" > "$OPS/ortam.tmp" && mv -f "$OPS/ortam.tmp" "$OPS/ortam"; } 2>/dev/null || rm -f "$OPS/ortam.tmp"
}
if [ "$KAYNAK" = cron ] && [ -z "$MODE" ] && [ "$INTERAKTIF" = 0 ]; then write_ortam; fi

# ── yeniden üretilebilirlik: yayından yeniden üretilemeyen dosya (hattın klasörüne sonradan konmuş) silinmez ──────────
# $1 = klasör (files/ alt klasörüyle), $2 = özet listesi → files/ içinde listede olmayan ya da değişmiş dosyalar
unrepro() {
  local s="$1" l="$2"
  [ -d "$s/files" ] || return 0
  if [ ! -f "$l" ]; then (cd "$s/files" && find . -type f | sed 's#^\./##'); return 0; fi
  tree_sums "$s/files" | comm -23 - <(sort "$l") | sed 's/^[0-9a-f]\{64\}  //'
}
# $1 = klasör, $2 = özet listesi, $3 = günlük bağlamı → silinebilirse 0; değilse .keep (dosya listesiyle) yazar,
# günlüğe düşer, 1 döner (dosya sayısı $GUARD_N'de)
keep_guard() {
  local s="$1" u
  GUARD_N=0
  [ -f "$s/.keep" ] && return 1
  u=$(unrepro "$s" "$2")
  [ -z "$u" ] && return 0
  GUARD_N=$(printf '%s\n' "$u" | wc -l | tr -d ' ')
  { echo "yayından yeniden üretilemeyen $GUARD_N dosya — elle silinene kadar saklanır:"; printf '%s\n' "$u" | head -50; } > "$s/.keep" 2>/dev/null
  log "uyarı: $3 yayına ait olmayan ya da değişmiş $GUARD_N dosya var (sitede artık yok) — KALICI: $s/files · $(printf '%s\n' "$u" | head -5 | tr '\n' ' ')"
  return 1
}
# anlık görüntü: files/ = önceki kurulumun girdileri → önceki kurulumun özet listesiyle (.prev-sums)
snap_guard() { keep_guard "$1" "$1/.prev-sums" "anlık görüntüde ($1)"; }

# ── geri dönüş (otomatik, yarım kurulum kurtarma, --geri-al) ─────────────────────────────────────────────────────
# $1 = anlık görüntü klasörü. Günlükten bağımsızdır: kurulumdan ÖNCE yazılan .top-before / .to-install listeleri
# ve files/ içeriği yeter. (.to-install − .top-before) = yeni sürümün getirdiği adlar → kenara; files/ altındaki
# her girdi yerine. Var olan bir girdinin üzerine asla taşımaz. Anlık görüntüyü silmez (finish_snap).
# Kenara alınanlar $OPS/failed/<zaman>/files/ (yer yoksa anlık görüntüde geri-alinan/files/): geri alınan sürümün
# özet listesinde (.new-sums) olmayan ya da değişmiş dosya varsa (hattın klasörüne sonradan konmuş) klasör KALICI (.keep).
rollback() {
  local s="$1" fd fdf e rc=0 lst sub="" tops
  RB_NOTE=""
  fd="$OPS/failed/$(date '+%Y%m%d-%H%M%S')-$$"
  if ! mkdir -p "$fd/files" 2>/dev/null; then
    fd="$s/geri-alinan"
    mkdir -p "$fd/files" 2>/dev/null || fd=""
    log "geri dönüş: uyarı — $OPS/failed açılamadı (kota?); ${fd:-kenara alma klasörü de açılamadı}"
  fi
  fdf="${fd:+$fd/files}"
  if [ -f "$s/.to-install" ]; then lst="$s/.to-install"; sub="$s/.top-before"; else lst="$s/.moved-in"; fi
  # 1) yeni sürümün getirdiği (kurulumdan önce web kökünde olmayan) girdiler kenara
  if [ -f "$lst" ]; then
    while IFS= read -r e; do
      [ -n "$e" ] || continue
      if [ -n "$sub" ] && in_list "$e" "$sub"; then continue; fi
      exists "$WEBROOT/$e" || continue
      if [ -z "$fdf" ] || exists "$fdf/$e" || ! mv "$WEBROOT/$e" "$fdf/$e"; then rc=1; log "geri dönüş: HATA — $e kenara alınamadı"; fi
    done < "$lst"
  fi
  # 2) anlık görüntüdeki her girdi yerine (aynı adla bir şey varsa önce o kenara; alınamazsa bu girdi atlanır)
  tops=$(list_top "$s/files")
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    if exists "$WEBROOT/$e"; then
      if [ -z "$fdf" ] || exists "$fdf/$e" || ! mv "$WEBROOT/$e" "$fdf/$e"; then rc=1; log "geri dönüş: HATA — $e yerine konamadı (aynı adla girdi kenara alınamadı)"; continue; fi
    fi
    if exists "$WEBROOT/$e"; then rc=1; continue; fi
    mv "$s/files/$e" "$WEBROOT/$e" || { rc=1; log "geri dönüş: HATA — $e yerine konamadı"; }
  done <<EOF
$tops
EOF
  # 3) kenara alınanlar yayından yeniden üretilebiliyor mu? (özet listesi klasöre kopyalanır; budama da ona bakar)
  if [ -n "$fd" ]; then
    if rmdir "$fdf" 2>/dev/null; then
      rmdir "$fd" 2>/dev/null
    else
      [ -f "$s/.new-sums" ] && cp "$s/.new-sums" "$fd/.sums" 2>/dev/null
      keep_guard "$fd" "$fd/.sums" "geri dönüşte kenara alınan girdilerde ($fd)" ||
        RB_NOTE="; UYARI: geri dönüşte yayına ait olmayan $GUARD_N dosya kenara alındı → $fdf (KALICI, elle bakın)"
    fi
  fi
  log "geri dönüş: önceki girdiler yerine kondu$([ -d "$fdf" ] && echo "; geri alınan sürümün dosyaları → $fdf")$([ "$rc" = 0 ] || echo ' (BAZI TAŞIMALAR BAŞARISIZ — elle bakın)')"
  return "$rc"
}
# Geri alınmış anlık görüntü: boşaldıysa silinir; yerine konamayan ya da (yedek yoldaki geri-alinan/ içinde)
# yayından yeniden üretilemeyen bir şey kaldıysa kalıcı işaretlenir
finish_snap() {
  local s="$1" ga="$1/geri-alinan"
  if [ -d "$ga" ]; then
    rmdir "$ga/files" 2>/dev/null && rmdir "$ga" 2>/dev/null
    if [ -d "$ga" ] && keep_guard "$ga" "$s/.new-sums" "geri dönüşte kenara alınan girdilerde ($ga)"; then rm -rf "$ga"; fi
  fi
  if [ ! -e "$ga" ] && rmdir "$s/files" 2>/dev/null; then rm -rf "$s"; return 0; fi
  touch "$s/.rolled-back" 2>/dev/null
  [ -f "$s/.keep" ] || echo "geri dönüşte yerine konamayan (files/) ya da yayına ait olmayan (geri-alinan/) girdiler — elle bakın" > "$s/.keep" 2>/dev/null
  return 0
}
# Canlı sürüm kaydı ve yönetilen liste, anlık görüntünün kurulumundan önceki hâline
restore_prev_state() {
  local s="$1" p
  p=$(cat "$s/.prev_sha" 2>/dev/null || true)
  if [ -n "$p" ]; then echo "$p" > "$OPS/current_sha"; else rm -f "$OPS/current_sha"; fi
  if [ -f "$s/.prev-managed" ]; then cp "$s/.prev-managed" "$OPS/yonetilen.txt"; else rm -f "$OPS/yonetilen.txt"; fi
  if [ -f "$s/.prev-sums" ]; then cp "$s/.prev-sums" "$OPS/yonetilen.sums"; else rm -f "$OPS/yonetilen.sums"; fi
}
# $1 = anlık görüntü, $2 = kurulum | geri-al → yarım kalırsa sonraki çalışma bunu geri alır
mark_start() {
  printf '%s\n%s\n' "$1" "$2" > "$OPS/kurulum-suruyor.tmp" && mv -f "$OPS/kurulum-suruyor.tmp" "$OPS/kurulum-suruyor" &&
    [ "$(sed -n 1p "$OPS/kurulum-suruyor" 2>/dev/null)" = "$1" ]
}
rollback_failed() { # $1 = bağlam; işaret (kurulum-suruyor) kalır → her çalışma geri dönüşü yeniden dener, yeni sürüm kurulmaz
  log "!!! GERİ DÖNÜŞ TAMAMLANAMADI ($1) — web kökü karışık durumda olabilir. Anlık görüntü: $(sed -n 1p "$OPS/kurulum-suruyor" 2>/dev/null). Her çalışma geri dönüşü yeniden dener; yeni sürüm kurulmaz. Elle bakın (DEPLOY.md §9)."
  status rollback-failed "$1: geri dönüş tamamlanamadı — elle bakın"
}
# Elle geri dönüşün sonu (anlık görüntü yerine kondu)
finish_manual() {
  local s="$1" s_sha prev
  s_sha=$(cat "$s/.sha" 2>/dev/null || true)
  restore_prev_state "$s"
  finish_snap "$s"
  [ -n "$s_sha" ] && echo "$s_sha" >> "$OPS/bad_shas"
  [ -n "$s_sha" ] && echo "$s_sha" > "$OPS/last_sha"
  prev=$(cat "$OPS/current_sha" 2>/dev/null || true)
  echo "${prev:--}" > "$OPS/.son-geri-al"
  rm -f "$OPS/kurulum-suruyor"
  log "geri-al: $s_sha geri alındı; canlı: ${prev:-kurulum öncesi site}. Bu sürüm bir daha kurulmaz; düzeltme yeni bir yayınla gelir."
  status manual-rollback "$s_sha geri alındı$RB_NOTE"
}

# Yarıda kalan kurulum (öldürülen çalışma, kapanan Terminal, sunucu yeniden başlaması) → önce o geri alınır
RECOVERED=0
recover_half() {
  local m="$OPS/kurulum-suruyor" s kind note
  [ -f "$m" ] || return 0
  s=$(sed -n 1p "$m"); kind=$(sed -n 2p "$m")
  case "$s" in
    "$OPS"/snapshots/?*) case "$s" in */../*|*/..) s="" ;; esac ;;
    *) s="" ;;
  esac
  if [ -z "$s" ]; then log "HATA: $m geçersiz — elle bakın"; status rollback-failed "yarım kurulum işareti geçersiz"; exit 1; fi
  if [ ! -d "$s" ]; then log "uyarı: yarım kurulum işareti var ama anlık görüntü yok ($s) — işaret silindi"; rm -f "$m"; return 0; fi
  sha=$(cat "$s/.sha" 2>/dev/null || true); rid=$(cat "$s/.rid" 2>/dev/null || true); seq=""
  log "kurtarma: yarıda kalan ${kind:-kurulum} bulundu ($s) — geri alınıyor"
  if ! rollback "$s"; then rollback_failed "yarım kalan ${kind:-kurulum}"; exit 1; fi
  RECOVERED=1
  if [ "$kind" = geri-al ]; then finish_manual "$s"; return 0; fi
  restore_prev_state "$s"
  finish_snap "$s"
  rm -f "$m"
  if [ -n "$sha" ] && grep -qx "$sha" "$OPS/yarida" 2>/dev/null; then
    echo "$sha" > "$OPS/last_sha"
    note="yarıda kalan kurulum geri alındı (bu sürümde ikinci kez) — kendiliğinden yeniden denenmez; yeni yayın ya da $OPS/last_sha'yı silin"
  else
    [ -n "$sha" ] && echo "$sha" >> "$OPS/yarida"
    note="yarıda kalan kurulum geri alındı; önceki site canlı (sürüm bir kez yeniden denenecek)"
  fi
  log "kurtarma: $note"
  status interrupted "$note$RB_NOTE"
}
on_signal() {
  trap '' HUP INT TERM
  SINYAL="$1"
  log "sinyal ($1): kurulum yarıda kesildi — geri alınıyor"
  recover_half
  exit 1
}

# Son kurulumun anlık görüntüsü (kurulumu hiç başlamamış, yarım hazırlanmış anlık görüntüler sayılmaz)
last_installed() { for d in "$OPS"/snapshots/*/; do [ -f "$d.installed" ] && printf '%s\n' "${d%/}"; done | sort | tail -1; }
# $1 = beklenen canlı sürüm (boş: son kurulum), $2 = 1 ise art arda ikinci adıma izin
manual_rollback() {
  local want="$1" again="$2" last s_sha cur
  cur=$(cat "$OPS/current_sha" 2>/dev/null || true)
  if [ -n "$want" ] && [ "$want" != "$cur" ]; then
    log_once "geri-al-sha-$want-$cur" "geri-al: canlı sürüm ${cur:-yok}, istenen $want değil — hiçbir şey yapılmadı (bu komut tek seferliktir)"; return 1
  fi
  if [ "$again" != 1 ] && [ "$(cat "$OPS/.son-geri-al" 2>/dev/null)" = "${cur:--}" ]; then
    log_once "geri-al-tekrar-$cur" "geri-al: son elle geri dönüşten sonra yeni kurulum olmadı — bir adım daha geri gitmek için: deploy.sh --geri-al --tekrar"; return 1
  fi
  last=$(last_installed)
  if [ -z "$last" ] || [ ! -f "$last/.installed" ] || [ -f "$last/.rolled-back" ]; then
    log "geri-al: geri alınacak kurulum yok"; return 1
  fi
  s_sha=$(cat "$last/.sha" 2>/dev/null || true)
  if [ -z "$s_sha" ] || [ "$s_sha" != "$cur" ]; then
    log "geri-al: son anlık görüntü (${s_sha:-?}) canlı sürümle (${cur:-?}) uyuşmuyor — elle bakın: $last"; return 1
  fi
  sha="$s_sha"; rid=$(cat "$last/.rid" 2>/dev/null || true); seq=""
  if ! mark_start "$last" geri-al; then log "geri-al: HATA — $OPS/kurulum-suruyor yazılamadı (disk?); hiçbir şey yapılmadı"; return 1; fi
  if ! rollback "$last"; then rollback_failed "geri-al"; return 1; fi
  finish_manual "$last"
  return 0
}

recover_half
case "$MODE" in
  --geri-al)
    if [ "$RECOVERED" = 1 ]; then
      [ -n "${sha:-}" ] && ! grep -qx "$sha" "$OPS/bad_shas" 2>/dev/null && echo "$sha" >> "$OPS/bad_shas"
      log "geri-al: yarıda kalan kurulum geri alındı — ek bir adım yapılmadı"; exit 0
    fi
    case "$MARG" in
      '') manual_rollback "" 0 ;;
      --tekrar) manual_rollback "" 1 ;;
      *) case "$MARG" in *[!0-9a-f]*) echo "kullanım: deploy.sh --geri-al [--tekrar | <40 haneli sha>]" >&2; exit 2 ;; esac
         [ ${#MARG} -eq 40 ] || { echo "sha 40 haneli olmalı" >&2; exit 2; }
         manual_rollback "$MARG" 1 ;;
    esac
    exit $? ;;
  '') ;;
  *) echo "kullanım: deploy.sh [--geri-al [--tekrar | <sha>]]" >&2; exit 2 ;;
esac
# Terminal'i olmayanlar için: Dosya Yöneticisi'nden $OPS/GERI-AL oluşturulur → bir adım geri, dosya silinir.
# Dosya, oluşturulduğu anda canlı olan sürümü geri alır: son kurulum dosyadan SONRA canlıya çıktıysa (dosya kurulum
# sürerken oluşturuldu) işlenmez — yoksa kaçılmak istenen sürüm geri gelir, yeni sürüm kara listeye girerdi.
# İçinde 40 haneli sha varsa --geri-al <sha> gibi: yalnız canlı sürüm oysa.
if [ -e "$OPS/GERI-AL" ]; then
  ga_want=$(grep -o '[0-9a-f]\{40\}' "$OPS/GERI-AL" 2>/dev/null | head -1)
  ga_old=0
  ga_last=$(last_installed)
  if [ -n "$ga_last" ]; then
    ga_ref="$ga_last/.live"; [ -f "$ga_ref" ] || ga_ref="$ga_last/.installed"
    [ "$OPS/GERI-AL" -nt "$ga_ref" ] || ga_old=1
  fi
  if ! rm -f "$OPS/GERI-AL"; then log_once "geri-al-dosya" "geri-al: $OPS/GERI-AL silinemedi — işlenmedi (tekrarı önlemek için)"; exit 1; fi
  if [ "$RECOVERED" = 1 ]; then log "geri-al: GERI-AL dosyası — yarıda kalan kurulum zaten geri alındı, ek adım yok"; exit 0; fi
  if [ -n "$ga_want" ]; then
    log "geri-al: GERI-AL dosyası ($ga_want) — yalnız canlı sürüm buysa geri alınır"
    manual_rollback "$ga_want" 1; exit $?
  fi
  if [ "$ga_old" = 1 ]; then
    sha=$(cat "$OPS/current_sha" 2>/dev/null || true); rid=""; seq=""
    log "geri-al: GERI-AL dosyası İŞLENMEDİ — dosya oluşturulduktan sonra yeni sürüm (${sha:-?}) kuruldu. Bu sürümü de geri almak istiyorsanız dosyayı yeniden oluşturun."
    status rollback-skipped "GERI-AL oluşturulduktan sonra yeni sürüm (${sha:0:12}) kuruldu — işlenmedi; hâlâ geri almak istiyorsanız dosyayı yeniden oluşturun"
    exit 0
  fi
  log "geri-al: GERI-AL dosyası bulundu (Dosya Yöneticisi) — son kurulum geri alınıyor"
  manual_rollback "" 1; exit $?
fi

# ── araçlar ──────────────────────────────────────────────────────────────────────────────────────────────────────
if ! command -v openssl >/dev/null 2>&1; then log_once "openssl-yok" "HATA: openssl yok — imza doğrulanamaz, kurulum yapılmaz"; status blocked "openssl yok"; exit 1; fi
# stdin'deki PEM bloklarını $1 klasörüne k1.pem, k2.pem … olarak yazar
split_keys() { awk -v d="$1" '/^-----BEGIN PUBLIC KEY-----$/{n++; f=d "/k" n ".pem"} f{print > f} /^-----END PUBLIC KEY-----$/{close(f); f=""}'; }
# $1 = betik dosyası → yalnız gömülü heredoc bloğu
script_keys() { awk '/^HEDEF_ACIK_ANAHTAR$/{on=0} on{print} /^cat <<.HEDEF_ACIK_ANAHTAR.$/{on=1}' "$1"; }
KEYDIR=$(mktemp -d "$OPS/.anahtar.XXXXXX") || exit 1
pubkeys | split_keys "$KEYDIR"
if ! ls "$KEYDIR"/k*.pem >/dev/null 2>&1; then log_once "anahtar-yok" "HATA: betikte gömülü açık anahtar yok"; status blocked "açık anahtar yok"; exit 1; fi

# $1 = SHA256SUMS, $2 = imza, $3 = anahtar klasörü → herhangi bir anahtarla doğrulanırsa 0
verify_sig() {
  local k
  for k in "$3"/k*.pem; do
    [ -f "$k" ] || continue
    openssl dgst -sha256 -verify "$k" -signature "$2" "$1" >/dev/null 2>&1 && return 0
  done
  return 1
}

# ── uzak sürüm ───────────────────────────────────────────────────────────────────────────────────────────────────
# Takılan bağlantı kilidi süresiz tutmasın: düşük hız sınırı + süre sınırı; ağ süreçleri kilit dosyasını (fd 9) devralmaz
sha="${TEST_SHA:-}"
if [ -z "$sha" ] && command -v git >/dev/null 2>&1; then
  sha=$(run_limited "$GIT_TIMEOUT" env GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=20 \
    git ls-remote "https://github.com/$REPO.git" "refs/heads/$BRANCH" 2>/dev/null 9>&- | cut -f1)
fi
if [ ${#sha} -ne 40 ]; then # git yoksa: aynı ref listesi düz HTTP ile (API kotasına takılmaz)
  sha=$(curl -fsS --connect-timeout 10 --max-time 20 "https://github.com/$REPO.git/info/refs?service=git-upload-pack" 2>/dev/null 9>&- |
    tr -d '\000' | grep -a -o "[0-9a-f]\{40\} refs/heads/$BRANCH\$" | head -1 | cut -c1-40)
fi
if [ ${#sha} -ne 40 ]; then
  sha=$(curl -fsS --connect-timeout 10 --max-time 20 -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/$REPO/commits/$BRANCH" 2>/dev/null 9>&- | tr -dc '0-9a-f' | head -c 40)
fi
case "$sha" in
  *[!0-9a-f]*|'') sha="" ;;
esac
if [ ${#sha} -ne 40 ]; then log_once "uzak-yok" "uzak: sürüm okunamadı (ağ/GitHub) — sonraki çalışmada tekrar"; exit 0; fi

[ "$sha" = "$(cat "$OPS/current_sha" 2>/dev/null)" ] && exit 0
[ "$sha" = "$(cat "$OPS/last_sha" 2>/dev/null)" ] && exit 0
grep -qx "$sha" "$OPS/bad_shas" 2>/dev/null && exit 0
# Tetik yalnız YENİ sürüm içindir: bu sürüm zaten doğrulanmış ve bekliyor (blocked, backup-failed, yarım kalan kurulumun
# yeniden denemesi) → cron her dakika dener; tetik paketi yeniden doğrulamaz, uapi çağırmaz, günlüğe yazmaz
if [ "$KAYNAK" = tetik ] && [ "$RECOVERED" = 0 ] && [ "$sha" = "$(cut -d' ' -f2 "$OPS/seen" 2>/dev/null)" ]; then exit 0; fi
# yeni sürüm: tetikli çalışmanın başlığı şimdi (indirme/kurulum sırasında öldürülürse "başladı var, bitti yok" görünür)
baslik_yaz

rid=""; seq=""
rel="$OPS/releases/$sha"
inc="$OPS/incoming"
# Önce yer açılır (dolu disk/kota bad_shas'ı yazdırmasın), sonra kayıt; yazılamazsa günlüğe düşer
reject() {
  rm -rf "$inc" "$rel"
  rm -f "$OPS/.son-not"
  log "doğrulama: REDDEDİLDİ $sha — $*"
  { echo "$sha" >> "$OPS/bad_shas"; } 2>/dev/null || log "HATA: bad_shas yazılamadı (disk dolu?) — sürüm her çalışmada yeniden denetlenecek"
  status invalid "$*" 2>/dev/null || log "HATA: status.json yazılamadı"
  exit 1
}

# ── indir + güvenli aç (imza AÇMADAN önce) ───────────────────────────────────────────────────────────────────────
safe_extract() { # $1 = tar.gz, $2 = hedef klasör; hata nedeni → $why
  local tgz="$1" dest="$2" pre="$2.imza" names types bad top root lit="" n bytes max files want dirs wantd
  why=""
  # GNU tar listede ASCII dışı adları \ ile kaçırır; ham ad gerekli
  tar --version 2>/dev/null | grep -q 'GNU tar' && lit="--quoting-style=literal"
  # 1) açılmış boyut ve girdi sayısı sınırlı (sıkıştırma bombası): akış sınırdan sonra kesilir, diske bir şey yazılmaz
  max=$((MAX_UNPACK_MB * 1048576))
  bytes=$(gzip -dc "$tgz" 2>/dev/null | head -c $((max + 1)) | wc -c | tr -d ' ')
  [ "${bytes:-0}" -le "$max" ] || { why="arşiv güvenli değil: açılmış boyut $MAX_UNPACK_MB MB sınırını aşıyor"; return 1; }
  names=$(tar $lit -tzf "$tgz" 2>/dev/null) || { why="arşiv güvenli değil: arşiv okunamadı"; return 1; }
  [ -n "$names" ] || { why="arşiv güvenli değil: boş arşiv"; return 1; }
  n=$(printf '%s\n' "$names" | wc -l | tr -d ' ')
  [ "$n" -le "$MAX_ENTRIES" ] || { why="arşiv güvenli değil: $n girdi (sınır $MAX_ENTRIES)"; return 1; }
  bad=$(printf '%s\n' "$names" | grep -E '(^/|(^|/)\.\.(/|$)|\\)' | head -3 | tr '\n' ' ' | ascii)
  [ -z "$bad" ] || { why="arşiv güvenli değil: tehlikeli yol (mutlak ya da ..): $bad"; return 1; }
  top=$(printf '%s\n' "$names" | cut -d/ -f1 | sort -u | wc -l | tr -d ' ')
  [ "$top" = 1 ] || { why="arşiv güvenli değil: arşivde tek kök klasör yok"; return 1; }
  root=$(printf '%s\n' "$names" | head -1 | cut -d/ -f1)
  types=$(tar $lit -tvzf "$tgz" 2>/dev/null) || { why="arşiv güvenli değil: arşiv okunamadı"; return 1; }
  bad=$(printf '%s\n' "$types" | cut -c1 | grep -v '^[-d]$' | sort -u | tr '\n' ' ' | ascii)
  [ -z "$bad" ] || { why="arşiv güvenli değil: düz dosya/klasör dışı girdi (sembolik/sabit bağ, aygıt …): tür '$bad'"; return 1; }
  # yalnız <kök>/, <kök>/public/…, <kök>/_ops/…, <kök>/README.md
  bad=$(printf '%s\n' "$names" | grep -v -E '^[^/]+/?$|^[^/]+/(public|_ops)(/|$)|^[^/]+/README\.md$' | head -3 | tr '\n' ' ' | ascii)
  [ -z "$bad" ] || { why="arşiv güvenli değil: beklenmeyen kök girdi: $bad"; return 1; }
  # 2) açmadan önce imza: yalnız SHA256SUMS ve imzası çıkarılır
  printf '%s\n' "$names" | grep -qxF "$root/_ops/SHA256SUMS" || { why="SHA256SUMS yok (imzasız paket)"; return 1; }
  printf '%s\n' "$names" | grep -qxF "$root/_ops/SHA256SUMS.sig" || { why="SHA256SUMS.sig yok (imzasız paket)"; return 1; }
  rm -rf "$pre" && mkdir -p "$pre" || { why="klasör açılamadı"; return 1; }
  if ! tar -xzf "$tgz" -C "$pre" --strip-components=1 "$root/_ops/SHA256SUMS" "$root/_ops/SHA256SUMS.sig" 2>/dev/null ||
     [ ! -f "$pre/_ops/SHA256SUMS" ] || [ ! -f "$pre/_ops/SHA256SUMS.sig" ]; then
    why="arşiv güvenli değil: imzalı liste açılamadı"; return 1
  fi
  verify_sig "$pre/_ops/SHA256SUMS" "$pre/_ops/SHA256SUMS.sig" "$KEYDIR" ||
    { why="İMZA doğrulanamadı (yanlış anahtar ya da değiştirilmiş liste) — arşiv açılmadı"; return 1; }
  # 3) arşivdeki dosya kümesi = imzalı liste (+ listenin kendisi, imza, README.md); fazlası açılmaz
  files=$(printf '%s\n' "$names" | grep -v '/$' | cut -d/ -f2- | grep -vxF -e '_ops/SHA256SUMS' -e '_ops/SHA256SUMS.sig' -e 'README.md' | sort)
  want=$(sed -n 's/^[0-9a-f]\{64\}  //p' "$pre/_ops/SHA256SUMS" | sort)
  if [ "$files" != "$want" ]; then
    bad=$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$files") | grep '^[<>]' | head -4 | ascii | sed 's/^</imzalı:/; s/^>/arşivde:/' | tr '\n' ';')
    why="SHA256SUMS uyuşmuyor (arşivde imzalı listede olmayan ya da eksik dosya; açılmadı): $bad"; return 1
  fi
  # klasörler de imzaya bağlı: yalnız imzalı dosyaların ata klasörleri. Git boş klasör taşımaz; alt modül girdisi
  # (gitlink) arşivde BOŞ KLASÖR olur ve imzasız bir ad koyardı (ör. chunks/.htaccess klasörü → JS/CSS 403)
  dirs=$(printf '%s\n' "$names" | grep '/$' | cut -d/ -f2- | sed 's#/$##' | grep -v '^$' | sort -u)
  wantd=$(printf '%s\n' "$want" | awk -F/ '{ p = $1; print p; for (i = 2; i < NF; i++) { p = p "/" $i; print p } }' | sort -u)
  bad=$(comm -23 <(printf '%s\n' "$dirs") <(printf '%s\n' "$wantd") | grep -v '^$' | head -3 | tr '\n' ' ' | ascii)
  [ -z "$bad" ] || { why="arşivde imzalı listeye ait olmayan (boş) klasör — alt modül girdisi olabilir; açılmadı: $bad"; return 1; }
  rm -rf "$pre"
  # 4) ancak şimdi tam açma
  mkdir -p "$dest" || { why="klasör açılamadı"; return 1; }
  tar -xzf "$tgz" -C "$dest" --strip-components=1 2>/dev/null || { why="açma hatası"; return 1; }
  return 0
}

# İndirme hatası (ağ, süre, kota) sha başına sayılır: 3 denemeden sonra saatte bir (aynı arşiv her dakika yeniden
# indirilip kotayı/trafiği tüketmesin); başarıda sayaç silinir
dl_n=0; dl_t=0
if { read -r dl_s dl_n dl_t < "$OPS/indirme-hata"; } 2>/dev/null && [ "$dl_s" = "$sha" ]; then
  case "$dl_n$dl_t" in ''|*[!0-9]*) dl_n=0; dl_t=0 ;; esac
else
  dl_n=0; dl_t=0
fi
dl_fail() { # $1 = neden
  rm -rf "$inc"
  dl_n=$((dl_n + 1))
  { printf '%s %s %s\n' "$sha" "$dl_n" "$(date +%s)" > "$OPS/indirme-hata"; } 2>/dev/null
  log "indirme: HATA ($sha, $dl_n. deneme) — $1; $([ "$dl_n" -ge 3 ] && echo 'bundan sonra saatte bir denenir' || echo 'sonraki çalışmada tekrar')"
  status blocked "indirme hatası ($dl_n. deneme): $1"
  exit 1
}
# $1 = hedef dosya. Boyut sınırı curl sürümünden bağımsız: akış head -c ile kesilir (curl 8.4'ten eski sürümler
# --max-filesize'ı boyutu önceden bilinmeyen — codeload gibi parça parça akan — yanıtta uygulamaz). Sınırı aşan
# arşiv reddedilir; hesapta yer azsa sınır boş alana (RESERVE_MB payı düşülerek) iner ve aşım "yer yok" sayılır.
download() {
  local out="$1" cap tight=0 fk room rc bytes url
  url="${TEST_DL_URL:-https://codeload.github.com/$REPO/tar.gz/$sha}"
  if [ "$dl_n" -ge 3 ] && [ $(( $(date +%s) - dl_t )) -lt 3600 ]; then rm -rf "$inc"; exit 0; fi
  cap=$((MAX_DL_MB * 1024))
  fk=$(free_kb "$OPS")
  if [ -n "$fk" ]; then
    room=$((fk - RESERVE_MB * 1024))
    if [ "$room" -lt 10240 ]; then
      rm -rf "$inc"
      log_once "yer-indir-$sha" "indirme: YAPILMADI — yer yok ($((fk / 1024)) MB boş, $RESERVE_MB MB pay korunur); yer açılınca kendiliğinden denenir"
      status blocked "indirme için yer yok ($((fk / 1024)) MB boş)"; exit 1
    fi
    if [ "$room" -lt "$cap" ]; then cap=$room; tight=1; fi
  fi
  { curl -fsSL --connect-timeout 10 --max-time 300 --max-filesize $((cap * 1024)) "$url" 2>/dev/null |
      head -c $((cap * 1024 + 1)) > "$out"; } 9>&-
  rc=$?
  bytes=$(wc -c < "$out" 2>/dev/null | tr -d ' ')
  if [ "${bytes:-0}" -gt $((cap * 1024)) ] || [ "$rc" = 63 ]; then
    [ "$tight" = 1 ] && dl_fail "yer yok: arşiv hesaptaki boş alanı ($((cap / 1024)) MB, $RESERVE_MB MB pay hariç) aşıyor"
    reject "arşiv çok büyük (> $MAX_DL_MB MB; indirme kesildi, açılmadı)"
  fi
  [ "$rc" = 0 ] || dl_fail "curl çıkış $rc (ağ, süre sınırı ya da yazma hatası)"
  rm -f "$OPS/indirme-hata"
}

if [ ! -d "$rel" ]; then
  rm -rf "$inc" && mkdir -p "$inc" "$OPS/releases"
  if [ -n "${TEST_RELEASE_DIR:-}" ]; then
    mkdir -p "$inc/x" && cp -R "$TEST_RELEASE_DIR/." "$inc/x/" || { log "test: paket kopyalanamadı"; exit 1; }
  else
    tgz="$inc/paket.tar.gz"
    if [ -n "${TEST_TARBALL:-}" ]; then
      cp "$TEST_TARBALL" "$tgz" || exit 1
    else
      download "$tgz"
    fi
    safe_extract "$tgz" "$inc/x" || reject "$why"
    rm -f "$tgz"
  fi
  # açtıktan sonra da: yalnız düz dosya ve klasör, adında satır sonu yok
  odd=$(find "$inc/x" ! -type f ! -type d | head -3 | tr '\n' ' ')
  [ -z "$odd" ] || reject "düz dosya/klasör dışı girdi: $odd"
  [ -z "$(find "$inc/x" -name "*$NL*" | head -1)" ] || reject "adında satır sonu olan dosya"
  mv "$inc/x" "$rel" || { log "hazırlık: HATA (releases)"; exit 1; }
  rm -rf "$inc"
fi
touch "$rel"

# ── doğrulama: imza → her dosya → sürüm → yapı ───────────────────────────────────────────────────────────────────
[ -d "$rel/public" ] && [ -d "$rel/_ops" ] || reject "public/ ya da _ops/ yok"
[ -f "$rel/_ops/SHA256SUMS" ] || reject "SHA256SUMS yok (imzasız paket)"
[ -f "$rel/_ops/SHA256SUMS.sig" ] || reject "SHA256SUMS.sig yok (imzasız paket)"
verify_sig "$rel/_ops/SHA256SUMS" "$rel/_ops/SHA256SUMS.sig" "$KEYDIR" || reject "İMZA doğrulanamadı (yanlış anahtar ya da değiştirilmiş liste)"

# İmzalı liste = gerçek ağaç (eksik, fazla ya da değişmiş dosya yok)
expected=$(LC_ALL=C sort "$rel/_ops/SHA256SUMS")
actual=$(cd "$rel" && find public _ops -type f ! -path '_ops/SHA256SUMS' ! -path '_ops/SHA256SUMS.sig' -print0 | sha_list | LC_ALL=C sort)
if [ "$expected" != "$actual" ]; then
  diffs=$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | grep '^[<>]' | head -4 | sed 's/^</imzalı:/; s/^>/pakette:/' | tr '\n' ';')
  reject "SHA256SUMS uyuşmuyor (değişmiş, eksik ya da fazladan dosya): $diffs"
fi
# boş klasör imzalı listeye bağlı değildir (git taşıyamaz; meşru yayında hiç olmaz)
empty=$(cd "$rel" && find public _ops -type d -empty | head -3 | tr '\n' ' ')
[ -z "$empty" ] || reject "imzalı listeye ait olmayan boş klasör (alt modül girdisi olabilir): $empty"

rid_get() { sed -n "s/^$1=\\([A-Za-z0-9._:+-]*\\)\$/\\1/p" "$rel/_ops/release-id" 2>/dev/null | head -1; }
rid=$(rid_get id); seq=$(rid_get seq); chan=$(rid_get channel)
[ -n "$rid" ] || reject "_ops/release-id: id yok"
case "$seq" in ''|*[!0-9]*) reject "_ops/release-id: sürüm numarası (seq) geçersiz" ;; esac
[ ${#seq} -le 15 ] || reject "_ops/release-id: sürüm numarası çok uzun"
[ "$chan" = "$CHANNEL" ] || reject "kanal uyuşmuyor (paket: ${chan:-yok}, sunucu: $CHANNEL) — test derlemesi canlıya kurulmaz"
seen_seq=0; seen_sha=""
if [ -f "$OPS/seen" ]; then read -r seen_seq seen_sha < "$OPS/seen"; fi
case "$seen_seq" in ''|*[!0-9]*) seen_seq=0 ;; esac
if [ "$seq" -lt "$seen_seq" ] || { [ "$seq" -eq "$seen_seq" ] && [ "$sha" != "$seen_sha" ]; }; then
  reject "eski sürüm numarası ($seq ≤ $seen_seq) — eski imzalı paketin yeniden sunulması (geri alma saldırısı) olabilir"
fi

for f in index.html .htaccess sitemap.xml 404.html robots.txt version.txt api/form.php; do
  [ -f "$rel/public/$f" ] || reject "zorunlu dosya yok: $f"
done
for f in deploy.sh urls.txt enabled release-id preserve.txt; do
  [ -f "$rel/_ops/$f" ] || reject "zorunlu dosya yok: _ops/$f"
done
case "$(head -1 "$rel/public/version.txt")" in "$rid"*) ;; *) reject "version.txt yayın kimliğiyle ($rid) uyuşmuyor" ;; esac
nfiles=$(find "$rel/public" -type f | wc -l | tr -d ' ')
[ "$nfiles" -ge "$MIN_FILES" ] || reject "dosya sayısı çok az ($nfiles < $MIN_FILES)"
badphp=$(cd "$rel/public" && find . -type f \( -iname '*.php' -o -iname '*.php[0-9]' -o -iname '*.phtml' -o -iname '*.phar' \) ! -path './api/*' | head -3 | tr '\n' ' ')
[ -z "$badphp" ] || reject "api/ dışında PHP dosyası: $badphp"
[ ! -e "$rel/public/api/_smtp.php" ] || reject "pakette api/_smtp.php var (şifre sızmış olabilir)"
SUPPORT=""
while IFS= read -r line || [ -n "$line" ]; do
  line=$(printf '%s' "$line" | tr -d '\r')
  case "$line" in ''|\#*) continue ;; esac
  case "$line" in *[!A-Za-z0-9._-]*|.*) reject "_ops/preserve.txt: geçersiz ad '$line'" ;; esac
  SUPPORT="$SUPPORT$line$NL"
done < "$rel/_ops/preserve.txt"
enabled=$(tr -dc '0-9' < "$rel/_ops/enabled")

printf '%s %s\n' "$seq" "$sha" > "$OPS/seen"
log "doğrulandı: $sha · $rid · $nfiles dosya · imza + SHA256SUMS tamam · kapı=${enabled:-0}"

# ── kendini güncelle (yalnız imzalı paketten; bash -n + paketi kendi anahtarıyla doğrulayabiliyorsa) ─────────────
self_update() {
  local new="$rel/_ops/deploy.sh" self="$0" kd
  case "$self" in deploy.sh|*/deploy.sh) ;; *) return 0 ;; esac
  [ -f "$self" ] || return 0
  cmp -s "$new" "$self" && return 0
  if ! bash -n "$new" 2>/dev/null; then log "betik: paketteki deploy.sh sözdizimi hatalı (bash -n) — güncellenmedi"; return 0; fi
  kd=$(mktemp -d "$OPS/.anahtar-yeni.XXXXXX") || return 0
  script_keys "$new" | split_keys "$kd"
  if ! verify_sig "$rel/_ops/SHA256SUMS" "$rel/_ops/SHA256SUMS.sig" "$kd"; then
    rm -rf "$kd"; log "betik: paketteki deploy.sh bu paketin imzasını kendi anahtarıyla doğrulayamıyor — güncellenmedi (kilitlenme önlendi)"; return 0
  fi
  rm -rf "$kd"
  if cp "$new" "$self.yeni" && chmod 700 "$self.yeni" && mv -f "$self.yeni" "$self"; then
    log "betik: deploy.sh imzalı paketten güncellendi (sha256=$(sha_file "$self"); sonraki çalışmada geçerli)"
  else
    rm -f "$self.yeni"; log "betik: güncelleme yazılamadı"
  fi
}
self_update

# ── korunanlar: sabit liste + destek dosyaları (imzalı preserve.txt) + başka alan adlarının belge kökleri (uapi) ─────
DOMAINS=""; DOCROOT_TOPS=""; uapi_ok=0; uapi_err=""; webroot_ok=0
read_docroots() {
  local u out d r rp cand base rest
  u=$(uapi_bin) || { uapi_err="uapi bulunamadı"; return 1; }
  out=$(run_limited 60 "$u" DomainInfo domains_data --output=json 2>/dev/null 9>&-) || { uapi_err="uapi hata verdi"; return 1; }
  out=$(printf '%s' "$out" | tr -d '\r\n')
  printf '%s' "$out" | grep -q '"status"[[:space:]]*:[[:space:]]*1' || { uapi_err="uapi başarısız (status≠1)"; return 1; }
  # jq yok: her nesne ayrı satıra, sonra domain + documentroot
  DOMAINS=$(printf '%s' "$out" | tr '{' '\n' | grep '"documentroot"' | while IFS= read -r obj; do
    d=$(printf '%s' "$obj" | sed -n 's/.*"domain"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    r=$(printf '%s' "$obj" | sed -n 's/.*"documentroot"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g')
    [ -n "$r" ] && printf '%s\t%s\n' "${d:-?}" "$r"
  done)
  [ -n "$DOMAINS" ] || { uapi_err="uapi çıktısında belge kökü yok"; return 1; }
  while IFS="$TAB" read -r d r; do
    [ -n "$r" ] || continue
    rp=$(phys "$r")
    for cand in "$r" "$rp"; do
      for base in "$WEBROOT" "$wr_phys"; do
        [ "$cand" = "$base" ] && webroot_ok=1
        case "$cand" in
          "$base"/*) rest=${cand#"$base"/}; DOCROOT_TOPS="$DOCROOT_TOPS${rest%%/*}$TAB$d$NL" ;;
        esac
      done
    done
  done <<EOF
$DOMAINS
EOF
  uapi_ok=1
  return 0
}

# $1 = kök girdi adı → korunuyorsa nedenini yazar ve 0 döner
preserve_reason() {
  local dr
  case "$1" in
    .well-known) echo "SSL doğrulaması (AutoSSL)"; return 0 ;;
    cgi-bin|.user.ini|php.ini|.ftpquota) echo "cPanel/PHP ayarı"; return 0 ;;
    .htpasswd*) echo "parola dosyası"; return 0 ;;
    error_log) echo "PHP hata günlüğü"; return 0 ;;
    google*.html|yandex_*.html|BingSiteAuth.xml) echo "arama motoru doğrulama dosyası"; return 0 ;;
  esac
  if printf '%s' "$SUPPORT" | grep -Fxq -- "$1"; then echo "destek sayfası indirme dosyası"; return 0; fi
  dr=$(printf '%s' "$DOCROOT_TOPS" | awk -F"$TAB" -v n="$1" '$1==n{print $2; exit}')
  if [ -n "$dr" ]; then echo "başka alan adının belge kökü ($dr)"; return 0; fi
  return 1
}

# Bu hat yalnız kendi kurduğu kök girdileri taşır ($OPS/yonetilen.txt, her başarılı kurulumda yazılır). Liste yoksa
# ilk kurulum: korunanlar dışındaki her şey taşınır ve o anlık görüntü kalıcıdır.
FIRST=0; [ -f "$OPS/yonetilen.txt" ] || FIRST=1
NEW_TOPS=""
mv_kind=""
# $1 = kök girdi → bu kurulumda anlık görüntüye taşınacaksa 0; $mv_kind: ilk | yonetilen | cakisma
will_move() {
  mv_kind=""
  preserve_reason "$1" >/dev/null && return 1
  if [ "$FIRST" = 1 ]; then mv_kind=ilk; return 0; fi
  if in_list "$1" "$OPS/yonetilen.txt"; then mv_kind=yonetilen; return 0; fi
  if printf '%s' "$NEW_TOPS" | grep -qxF -- "$1"; then mv_kind=cakisma; return 0; fi
  return 1
}

# WordPress: wp-config.php web kökünde ya da (WordPress'in desteklediği gibi) bir üstünde. Bulunursa 0; ayar yolu → $WPC
WP=0; WPC=""
wp_find() {
  local up
  up=$(dirname "$WEBROOT")
  if [ -f "$WEBROOT/wp-config.php" ]; then WP=1; WPC="$WEBROOT/wp-config.php"; return 0; fi
  if [ -f "$WEBROOT/wp-settings.php" ] || [ -f "$WEBROOT/wp-load.php" ] || [ -d "$WEBROOT/wp-includes" ] || [ -d "$WEBROOT/wp-content" ]; then
    WP=1
    if [ -f "$up/wp-config.php" ] && [ ! -f "$up/wp-settings.php" ]; then WPC="$up/wp-config.php"; fi
    return 0
  fi
  return 1
}

write_plan() {
  local e why d r
  {
    echo "# Hedef Teknoloji — yayın planı · $(ts)"
    echo "# kanal: $CHANNEL · sürüm: $rid · commit: $sha · kapı: $([ "$enabled" = 1 ] && echo 'AÇIK (kurulur)' || echo 'KAPALI (kurulmaz)')"
    echo "# web kökü: $WEBROOT"
    [ "$FIRST" = 1 ] && echo "# İLK KURULUM: bu hat web kökünde henüz bir şey kurmadı ($OPS/yonetilen.txt yok)"
    echo
    if [ "$uapi_ok" = 1 ]; then
      echo "## Alan adları ve belge kökleri (cPanel uapi)"
      printf '%s\n' "$DOMAINS" | while IFS="$TAB" read -r d r; do [ -n "$r" ] && echo "   $d → $r"; done
      [ "$webroot_ok" = 1 ] || echo "   !! web kökü hiçbir alan adının belge kökü değil — KURULUM YAPILMAZ (WEBROOT ayarını denetleyin)"
    else
      echo "## Alan adları OKUNAMADI ($uapi_err) — bu durumda KURULUM YAPILMAZ"
    fi
    echo
    echo "## KORUNACAK — yerinde kalır, dokunulmaz"
    list_top "$WEBROOT" | while IFS= read -r e; do why=$(preserve_reason "$e") && echo "   $e   ($why)"; done
    echo
    echo "## TAŞINACAK — anlık görüntüye ($OPS/snapshots/…); geri dönüşte yerine konur"
    list_top "$WEBROOT" | while IFS= read -r e; do
      will_move "$e" || continue
      why=""; [ "$mv_kind" = cakisma ] && why="   (yayına ait değil ama yeni sürümde aynı ad var — anlık görüntüde KALICI saklanır)"
      if [ -d "$WEBROOT/$e" ]; then echo "   $e/$why"; else echo "   $e$why"; fi
    done
    [ "$FIRST" = 1 ] && echo "   (ilk kurulum: bu anlık görüntü KALICIDIR — otomatik silinmez)"
    if [ "$FIRST" != 1 ]; then
      echo
      echo "## YAYINA AİT DEĞİL — yerinde kalır, taşınmaz, silinmez (bu hat yalnız kendi kurduğu girdileri taşır)"
      list_top "$WEBROOT" | while IFS= read -r e; do
        preserve_reason "$e" >/dev/null && continue
        will_move "$e" && continue
        if [ -d "$WEBROOT/$e" ]; then echo "   $e/"; else echo "   $e"; fi
      done
    fi
    echo
    echo "## GELECEK — yeni sürümün kök girdileri"
    list_top "$rel/public" | while IFS= read -r e; do
      if why=$(preserve_reason "$e"); then echo "   !! $e — korunan adla çakışıyor ($why), KURULMAZ"; else echo "   $e"; fi
    done
    if [ "$CHANNEL" = live ]; then
      echo
      echo "## Destek sayfası dosyaları (site kökünde durmalı; /destek/ indirmeleri)"
      printf '%s' "$SUPPORT" | while IFS= read -r e; do
        [ -n "$e" ] || continue
        if [ -f "$WEBROOT/$e" ]; then echo "   var    $e"; else echo "   !! YOK $e — indirme bağlantısı kırık olur; canlı testte denetleniyorsa kurulum geri alınır"; fi
      done
    fi
    if [ "$FIRST" = 1 ] && [ ! -f "$BACKUPS/.wp-ok" ]; then
      echo
      echo "## İlk kurulumdan hemen önce web kökünün tam yedeği → $BACKUPS"
      if [ "$WP" = 1 ] && [ -n "$WPC" ]; then
        echo "   WordPress bulundu (ayar: $WPC): veritabanı dökümü de alınır"
      elif [ "$WP" = 1 ]; then
        echo "   !! WordPress bulundu ama wp-config.php yok (web kökünde ya da bir üstünde) — veritabanı dökümü alınamaz;"
        echo "      veritabanını cPanel → Yedekleme'den indirip $BACKUPS/.db-atla oluşturun"
      fi
    fi
    if [ -f "$WEBROOT/.htaccess" ] && grep -q '^# .*BEGIN cPanel-generated' "$WEBROOT/.htaccess"; then
      echo
      echo "## Not: .htaccess'teki cPanel PHP bloğu (MultiPHP) yeni .htaccess'in başına taşınır"
    fi
  } > "$OPS/plan.txt.tmp" && mv -f "$OPS/plan.txt.tmp" "$OPS/plan.txt"
}

read_docroots || true
NEW_TOPS=$(list_top "$rel/public" | while IFS= read -r e; do preserve_reason "$e" >/dev/null || printf '%s\n' "$e"; done)
wp_find
write_plan

# ── kapı ─────────────────────────────────────────────────────────────────────────────────────────────────────────
if [ "$enabled" != 1 ]; then
  log "kapı: KAPALI (_ops/enabled=${enabled:-0}) — kurulum yok; plan: $OPS/plan.txt"
  status gated "kapı kapalı; plan.txt yazıldı"
  echo "$sha" > "$OPS/last_sha"
  rm -f "$OPS/.son-not"
  exit 0
fi
if [ "$uapi_ok" != 1 ]; then
  log_once "uapi-$sha-$uapi_err" "kurulum: YAPILMADI — alan adları okunamadı ($uapi_err); başka sitelerin klasörlerini korumak için uapi şart. Sonraki çalışmada tekrar."
  status blocked "uapi: $uapi_err"; exit 1
fi
if [ "$webroot_ok" != 1 ]; then
  log_once "wr-$sha" "kurulum: YAPILMADI — $WEBROOT hiçbir alan adının belge kökü değil (uapi)"
  status blocked "web kökü belge kökü değil"; exit 1
fi
if [ -n "$(find "$WEBROOT" -maxdepth 1 -name "*$NL*" | head -1)" ]; then
  log_once "nl-$sha" "kurulum: YAPILMADI — web kökünde adında satır sonu olan girdi var"; status blocked "tuhaf dosya adı"; exit 1
fi

# ── ilk kurulum: web kökünün tam yedeği (+ WordPress varsa veritabanı) — başarısızsa kurulum yok ────────────────────
# Önce ucuz denetimler (veritabanı bilgisi, mysqldump, yer), sonra döküm, en son tar. Başarısız denemenin her dosyası
# silinir (birikmez); kendiliğinden yeniden denenmez: $BACKUPS/.tekrar-dene (ya da .db-atla) ile bir kez daha.
# Süren deneme $BACKUPS/.yedek-suruyor'da (damga) ve kilit kaydında (aşama "yedek", sınır BACKUP_STUCK_MIN) işaretlidir:
# öldürülen / süre sınırına takılan / sunucu kapanmasıyla kesilen deneme sonraki çalışmada başarısız sayılır, dosyaları
# silinir — her çalışmada public_html'in tamamını yeniden okuyan sonsuz döngü olmaz.
BK_ARC=""; BK_DB=""
bk_fail() {
  rm -f ${BK_ARC:+"$BK_ARC"} ${BK_ARC:+"$BK_ARC.partial"} ${BK_DB:+"$BK_DB"} ${BK_DB:+"$BK_DB.partial"} "$BACKUPS/.yedek-suruyor"
  { printf '%s\ndb-atla=%s\n' "$1" "$([ -f "$BACKUPS/.db-atla" ] && echo 1 || echo 0)" > "$BACKUPS/.wp-fail"; } 2>/dev/null ||
    log "yedek: uyarı — $BACKUPS/.wp-fail yazılamadı (disk dolu?)"
  log "yedek: HATA — $1; KURULUM YAPILMADI. Düzeltince $BACKUPS/.tekrar-dene dosyasını oluşturun (otomatik yeniden deneme yok)."
  return 1
}
first_backup() {
  local stamp rc need DBN DBU DBP DBH host port sock
  [ "$FIRST" = 1 ] || return 0
  if [ -f "$BACKUPS/.yedek-suruyor" ]; then
    if [ -f "$BACKUPS/.wp-ok" ]; then
      rm -f "$BACKUPS/.yedek-suruyor"
    else
      stamp=$(sed -n 1p "$BACKUPS/.yedek-suruyor" 2>/dev/null | tr -dc '0-9-')
      BK_ARC=""; BK_DB=""
      if [ -n "$stamp" ]; then BK_ARC="$BACKUPS/ilk-kurulum-oncesi-$(basename "$WEBROOT")-$stamp.tar.gz"; BK_DB="$BACKUPS/wp-db-$stamp.sql.gz"; fi
      bk_fail "önceki ilk kurulum yedeği yarıda kesildi (süre sınırı, durdurma ya da sunucu yeniden başlaması; ${stamp:-?} denemesinin dosyaları silindi). Web kökü çok büyük/yavaşsa: cPanel → Yedekleme'den yedek alıp $BACKUPS/.wp-ok oluşturun"
      return 1
    fi
  fi
  [ -f "$BACKUPS/.wp-ok" ] && return 0
  if [ -e "$BACKUPS/.wp-fail" ]; then
    if [ -e "$BACKUPS/.tekrar-dene" ] || { [ -f "$BACKUPS/.db-atla" ] && grep -qx 'db-atla=0' "$BACKUPS/.wp-fail"; }; then
      rm -f "$BACKUPS/.tekrar-dene" "$BACKUPS/.wp-fail"; log "yedek: yeniden deneniyor (.tekrar-dene / .db-atla)"
    else
      log_once "yedek-bekle-$sha" "yedek: son deneme başarısızdı ($(head -1 "$BACKUPS/.wp-fail" 2>/dev/null)); kendiliğinden yeniden denenmez — düzeltip $BACKUPS/.tekrar-dene oluşturun"
      return 1
    fi
  fi
  stamp=$(date '+%Y%m%d-%H%M%S')
  BK_ARC="$BACKUPS/ilk-kurulum-oncesi-$(basename "$WEBROOT")-$stamp.tar.gz"
  BK_DB=""
  if [ "$WP" = 1 ] && [ ! -f "$BACKUPS/.db-atla" ]; then
    [ -n "$WPC" ] || { bk_fail "WordPress bulundu ama wp-config.php yok (web kökünde ya da bir üstünde); veritabanını cPanel → Yedekleme'den indirip $BACKUPS/.db-atla oluşturun"; return 1; }
    getv() { sed -n "s/^[[:space:]]*define([[:space:]]*['\"]$1['\"][[:space:]]*,[[:space:]]*['\"]\\(.*\\)['\"][[:space:]]*);.*/\\1/p" "$WPC" | head -1; }
    DBN=$(getv DB_NAME); DBU=$(getv DB_USER); DBP=$(getv DB_PASSWORD); DBH=$(getv DB_HOST)
    [ -n "$DBN" ] && [ -n "$DBU" ] || { bk_fail "veritabanı bilgisi $WPC içinden okunamadı; elle yedekleyip $BACKUPS/.db-atla oluşturun"; return 1; }
    command -v mysqldump >/dev/null 2>&1 || { bk_fail "mysqldump yok; veritabanını cPanel → Yedekleme'den indirip $BACKUPS/.db-atla oluşturun"; return 1; }
    BK_DB="$BACKUPS/wp-db-$stamp.sql.gz"
  fi
  need=$(du -sk "$WEBROOT" 2>/dev/null | awk '{print $1}')
  space_ok "${need:-0}" 10 "ilk kurulum yedeği ($(( ${need:-0} / 1024 )) MB)" "$BACKUPS" || { bk_fail "$why"; return 1; }
  { printf '%s\n' "$stamp" > "$BACKUPS/.yedek-suruyor"; } 2>/dev/null || { bk_fail "$BACKUPS/.yedek-suruyor yazılamadı (disk dolu?)"; return 1; }
  lock_phase yedek
  if [ -n "$BK_DB" ]; then
    host=${DBH:-localhost}; port=""; sock=""
    case "$host" in
      *:/*) sock=${host#*:}; host=${host%%:*} ;;
      *:*) port=${host#*:}; host=${host%%:*} ;;
    esac
    log "yedek: veritabanı ($DBN) dökülüyor → $BK_DB"
    if MYSQL_PWD="$DBP" mysqldump -h "$host" ${port:+-P "$port"} ${sock:+--socket="$sock"} -u "$DBU" \
         --single-transaction --no-tablespaces "$DBN" 2>>"$OPS/deploy.log" 9>&- | gzip > "$BK_DB.partial" && gzip -t "$BK_DB.partial" 2>/dev/null &&
       [ "$(gzip -dc "$BK_DB.partial" | head -c 64 | wc -c | tr -d ' ')" -gt 0 ] && mv -f "$BK_DB.partial" "$BK_DB"; then
      :
    else
      bk_fail "veritabanı dökümü başarısız (ayrıntı yukarıda); elle yedekleyip $BACKUPS/.db-atla oluşturabilirsiniz"; return 1
    fi
  fi
  log "yedek: ilk kurulumdan önce web kökü arşivleniyor → $BK_ARC"
  tar -czf "$BK_ARC.partial" -C "$(dirname "$WEBROOT")" "$(basename "$WEBROOT")" 2>>"$OPS/deploy.log" 9>&-; rc=$?
  # GNU tar 1 = "okunurken değişti" (ör. error_log) → arşiv sağlamsa kabul
  if [ "$rc" -gt 1 ] || ! gzip -t "$BK_ARC.partial" 2>/dev/null || [ -z "$(tar -tzf "$BK_ARC.partial" 2>/dev/null | head -1)" ] ||
     ! mv -f "$BK_ARC.partial" "$BK_ARC"; then
    bk_fail "web kökü arşivlenemedi (tar çıkış $rc; disk kotası?)"; return 1
  fi
  [ "$rc" = 1 ] && log "yedek: uyarı — bazı dosyalar arşivlenirken değişti (günlük dosyaları olabilir)"
  touch "$BACKUPS/.wp-ok" || { bk_fail "$BACKUPS/.wp-ok yazılamadı"; return 1; }
  rm -f "$BACKUPS/.wp-fail" "$BACKUPS/.yedek-suruyor"
  lock_phase kurulum
  log "yedek: tamam — $BK_ARC ($(du -h "$BK_ARC" | awk '{print $1}'))${BK_DB:+ + $BK_DB}"
  return 0
}
if ! first_backup; then status backup-failed "ilk kurulum yedeği alınamadı; kurulum yapılmadı — deploy.log, sonra $BACKUPS/.tekrar-dene"; exit 1; fi

# ── kurulum: yer → hazırla → anlık görüntü kayıtları → taşınacaklar dışarı → yeniler içeri (rename; aynı disk) ──────
need_kb=$(du -sk "$rel/public" 2>/dev/null | awk '{print $1}')
if ! space_ok "${need_kb:-0}" "$((nfiles + 200))" "kurulum" "$OPS"; then
  log_once "yer-$sha" "kurulum: YAPILMADI — $why"; status blocked "$why"; exit 1
fi
stage="$OPS/stage"
if ! { rm -rf "$stage" && mkdir -p "$stage" "$OPS/snapshots" && cp -R "$rel/public/." "$stage/"; }; then
  rm -rf "$stage"; log "hazırlık: HATA (kopyalama)"; status error "hazırlık: kopyalama"; exit 1
fi
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
# cPanel'in yönettiği bloklar (MultiPHP sürümü vb.) eski .htaccess'ten yenisine taşınır
if [ -f "$WEBROOT/.htaccess" ]; then
  blk=$(awk '/^# .*BEGIN cPanel-generated/{on=1; buf=""} on{buf=buf $0 "\n"} on && /^# .*END cPanel-generated/{printf "%s", buf; on=0}' "$WEBROOT/.htaccess")
  if [ -n "$blk" ]; then
    { printf '%s\n\n' "$blk"; cat "$stage/.htaccess"; } > "$stage/.htaccess.yeni" && mv -f "$stage/.htaccess.yeni" "$stage/.htaccess"
    log "htaccess: cPanel bloğu (PHP sürümü) yeni .htaccess'in başına taşındı"
  fi
fi

# kurulacak kök girdiler (korunan adlar kurulmaz)
TO_INSTALL=""
while IFS= read -r e; do
  [ -n "$e" ] || continue
  if why=$(preserve_reason "$e"); then log "uyarı: yeni sürümde korunan ad ($e — $why) — kurulmadı"; continue; fi
  TO_INSTALL="$TO_INSTALL$e$NL"
done <<EOF
$(list_top "$stage")
EOF

snap="$OPS/snapshots/$(date '+%Y%m%d-%H%M%S')-$seq"
[ -e "$snap" ] && snap="$snap-$$"
# Kayıtlar taşımaya BAŞLAMADAN yazılır; biri bile yazılamazsa web köküne dokunulmaz
prep_snap() {
  mkdir -p "$snap/files" &&
    printf '%s\n' "$sha" > "$snap/.sha" && printf '%s\n' "$rid" > "$snap/.rid" &&
    { if [ -f "$OPS/current_sha" ]; then cp "$OPS/current_sha" "$snap/.prev_sha"; else : > "$snap/.prev_sha"; fi; } &&
    { [ ! -f "$OPS/yonetilen.txt" ] || cp "$OPS/yonetilen.txt" "$snap/.prev-managed"; } &&
    { [ ! -f "$OPS/yonetilen.sums" ] || cp "$OPS/yonetilen.sums" "$snap/.prev-sums"; } &&
    tree_sums "$stage" > "$snap/.new-sums" &&
    list_top "$WEBROOT" > "$snap/.top-before" &&
    printf '%s' "$TO_INSTALL" > "$snap/.to-install" &&
    { [ "$FIRST" != 1 ] || echo "ilk kurulumdan önceki site — elle silinene kadar saklanır" > "$snap/.keep"; }
}
MOVE_OUT=""; FOREIGN=""; CONFLICT=""; prep_ok=0
if prep_snap; then
  prep_ok=1
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    preserve_reason "$e" >/dev/null && continue
    if will_move "$e"; then
      MOVE_OUT="$MOVE_OUT$e$NL"
      [ "$mv_kind" = cakisma ] && CONFLICT="$CONFLICT$e "
    else
      FOREIGN="$FOREIGN$e "
    fi
  done < "$snap/.top-before"
fi
if [ "$prep_ok" != 1 ] || { [ -n "$CONFLICT" ] && ! echo "yayına ait olmayan, yeni sürümle aynı adlı girdi: $CONFLICT — elle silinene kadar saklanır" > "$snap/.keep"; } ||
   ! mark_start "$snap" kurulum; then
  rm -rf "$snap" "$stage"; rm -f "$OPS/kurulum-suruyor"
  log "kurulum: YAPILMADI — anlık görüntü kayıtları yazılamadı (disk/inode kotası?); web köküne dokunulmadı"
  status error "anlık görüntü kayıtları yazılamadı; web köküne dokunulmadı"; exit 1
fi
[ -n "$CONFLICT" ] && log "uyarı: yayına ait olmayan ama yeni sürümde aynı adı taşıyan girdi(ler) anlık görüntüye alındı (KALICI): $CONFLICT→ $snap/files"

# Buradan sonra kesilirse (sinyal) hemen, öldürülürse sonraki çalışmada geri alınır
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
abort_install() { # $1 = neden
  log "taşıma: HATA ($1) — geri alınıyor"
  if rollback "$snap"; then
    restore_prev_state "$snap"; finish_snap "$snap"; rm -f "$OPS/kurulum-suruyor"
    status rolled-back "$1; önceki site geri kondu$RB_NOTE"
  else
    rollback_failed "$1"
  fi
  exit 1
}
t0=$(date +%s)
while IFS= read -r e; do
  [ -n "$e" ] || continue
  mv "$WEBROOT/$e" "$snap/files/$e" || abort_install "$e dışarı taşınamadı"
  [ -z "${TEST_MOVE_SLEEP:-}" ] || sleep "$TEST_MOVE_SLEEP"
done <<EOF
$MOVE_OUT
EOF
while IFS= read -r e; do
  [ -n "$e" ] || continue
  if exists "$WEBROOT/$e"; then abort_install "$e zaten var"; fi
  mv "$stage/$e" "$WEBROOT/$e" || abort_install "$e içeri taşınamadı"
  [ -z "${TEST_MOVE_SLEEP:-}" ] || sleep "$TEST_MOVE_SLEEP"
done <<EOF
$TO_INSTALL
EOF
touch "$snap/.installed"
rm -rf "$stage"
log "kuruldu: $rid ($nfiles dosya, $(( $(date +%s) - t0 )) sn; önceki site → $snap)"
[ -n "$FOREIGN" ] && log "uyarı: web kökünde yayına ait olmayan kök girdi(ler) yerinde bırakıldı (taşınmaz, silinmez): $FOREIGN"

# ── canlı test ───────────────────────────────────────────────────────────────────────────────────────────────────
pause() { [ "$PAUSE" = 0 ] || sleep "$PAUSE" 2>/dev/null || sleep 1; }
# sinyal beklerken de işlensin (sleep ön planda olsaydı trap onun bitmesini beklerdi)
if [ "$SETTLE" != 0 ]; then sleep "$SETTLE" 9>&- & wait $!; fi
site_host=${SITE_URL#*://}; site_host=${site_host%%/*}; site_host=${site_host%%:*}
site_ip="${RESOLVE_IP:-}"
bad=0; n=0; down=0
# $1 = adres → curl --resolve değeri (boşsa DNS). Başka ad (www) ana adın ilk yanıttaki IP'sine; RESOLVE_IP varsa hepsi ona.
pin_for() {
  local hostport h dp
  hostport=${1#*://}; hostport=${hostport%%/*}; h=${hostport%%:*}
  case "$hostport" in
    *:*) dp=${hostport##*:} ;;
    *) case "$1" in https://*) dp=443 ;; *) dp=80 ;; esac ;;
  esac
  if [ -n "$site_ip" ] && { [ "$h" != "$site_host" ] || [ -n "${RESOLVE_IP:-}" ]; }; then printf '%s:%s:%s' "$h" "$dp" "$site_ip"; fi
}
set -f
while IFS= read -r line || [ -n "$line" ]; do
  line=$(printf '%s' "$line" | tr -d '\r')
  case "$line" in ''|\#*) continue ;; esac
  # shellcheck disable=SC2086
  set -- $line
  m=HEAD
  case "$1" in GET|HEAD) m=$1; shift ;; esac
  u=${1:-}; want=${2:-}; loc=${3:-}
  case "$u" in http://*|https://*) url=$u ;; /*) url="$SITE_URL$u" ;; *) bad=$((bad+1)); log "test: HATA geçersiz satır: $line"; continue ;; esac
  case "$loc" in /*) loc="$SITE_URL$loc" ;; esac
  pin=$(pin_for "$url")
  hd=""; [ "$m" = HEAD ] && hd="-I"
  out=$(curl -sS $hd -o /dev/null -w '%{http_code} %{remote_ip} %{redirect_url}' --connect-timeout 5 --max-time 20 -A "$UA" \
    -H 'Cache-Control: no-cache' ${pin:+--resolve "$pin"} "$url" 2>/dev/null 9>&-)
  code=${out%% *}; rest=${out#* }; ip=${rest%% *}; got=${rest#* }; [ "$got" = "$rest" ] && got=""
  h=${url#*://}; h=${h%%/*}; h=${h%%:*}
  [ -z "$site_ip" ] && [ "$h" = "$site_host" ] && case "$ip" in *:*|'') ;; *) site_ip=$ip ;; esac
  n=$((n+1))
  if [ "$code" != "$want" ]; then bad=$((bad+1)); log "test: HATA $m $u → $code (beklenen $want)"
  elif [ -n "$loc" ] && [ "$got" != "$loc" ]; then bad=$((bad+1)); log "test: HATA $u → $got (beklenen $loc)"; fi
  # sunucu siteye hiç ulaşamıyorsa (3 kez üst üste bağlantı yok) beklemeden geri dön
  if [ "$code" = 000 ]; then down=$((down+1)); else down=0; fi
  if [ "$down" -ge 3 ]; then log "test: siteye bağlanılamıyor (3 kez 000) — test kesildi (sunucu kendine ulaşamıyorsa RESOLVE_IP=127.0.0.1, DEPLOY.md §9)"; break; fi
  pause
done < "$rel/_ops/urls.txt"
set +f
pin=$(pin_for "$SITE_URL/")
v=$(curl -fsS --connect-timeout 5 --max-time 20 -A "$UA" -H 'Cache-Control: no-cache' ${pin:+--resolve "$pin"} "$SITE_URL/version.txt?t=$(date +%s)" 2>/dev/null 9>&- | head -1)
n=$((n+1))
case "$v" in "$rid"*) ;; *) bad=$((bad+1)); log "test: HATA /version.txt canlıda '$v' (beklenen $rid)" ;; esac

if [ "$bad" -gt 0 ]; then
  log "test: $bad/$n hata — GERİ DÖNÜLÜYOR"
  if rollback "$snap"; then
    restore_prev_state "$snap"; finish_snap "$snap"; rm -f "$OPS/kurulum-suruyor"
    echo "$sha" >> "$OPS/bad_shas"
    status rolled-back "$bad/$n canlı test hatası; önceki site geri kondu$RB_NOTE"
  else
    rollback_failed "$bad/$n canlı test hatası"
  fi
  rm -f "$OPS/.son-not"
  exit 1
fi
# Başarı: önce yönetilen liste ve canlı sürüm, en son yarım-kurulum işareti (araya giren kesinti → geri alınır)
if ! { cp "$snap/.new-sums" "$OPS/yonetilen.sums.tmp" && mv -f "$OPS/yonetilen.sums.tmp" "$OPS/yonetilen.sums" &&
       cp "$snap/.to-install" "$OPS/yonetilen.txt.tmp" && mv -f "$OPS/yonetilen.txt.tmp" "$OPS/yonetilen.txt" &&
       printf '%s\n' "$sha" > "$OPS/current_sha.tmp" && mv -f "$OPS/current_sha.tmp" "$OPS/current_sha"; }; then
  echo "$sha" > "$OPS/last_sha" 2>/dev/null
  abort_install "canlı test geçti ama durum dosyaları yazılamadı (disk dolu?)"
fi
: > "$snap/.live"
echo "$sha" > "$OPS/last_sha"
rm -f "$OPS/kurulum-suruyor"
plain_traps
rm -f "$OPS/.son-not"

# ── anlık görüntü: yayından yeniden üretilemeyen dosya (yönetilen klasöre sonradan konmuş) varsa kalıcı (snap_guard) ──
note=""
[ -n "$FOREIGN" ] && note="; yayına ait olmayan $(printf '%s' "$FOREIGN" | wc -w | tr -d ' ') kök girdi yerinde bırakıldı (plan.txt)"
[ -n "$CONFLICT" ] && note="$note; yeni sürümle aynı adlı yabancı girdi anlık görüntüde KALICI (deploy.log)"
if [ "$FIRST" != 1 ] && ! snap_guard "$snap"; then note="$note; UYARI: taşınan klasörlerde yayına ait olmayan dosya vardı → anlık görüntü KALICI (deploy.log)"; fi
status live "$n/$n canlı test geçti$note"
log "test: $n/$n geçti — CANLI: $rid"

# ── temizlik: son $KEEP paket ve anlık görüntü, son 2 başarısız (geri alınan sürüm) klasörü; .keep'liler hariç ve
# silmeden önce yeniden üretilebilirlik (anlık görüntü: .prev-sums, başarısız: geri alınan sürümün özeti .sums)
prune_dirs() { # $1 = üst klasör, $2 = kalacak sayı, $3 = ad|zaman, $4 = 1: anlık görüntü, 2: başarısız klasörü
  local d k=0 list
  if [ "$3" = ad ]; then list=$(ls -1d "$1"/*/ 2>/dev/null | sort -r); else list=$(ls -1dt "$1"/*/ 2>/dev/null); fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    d=${d%/}
    [ -f "$d/.keep" ] && continue
    k=$((k+1))
    [ "$k" -le "$2" ] && continue
    if [ "${4:-0}" = 1 ]; then snap_guard "$d" || continue; fi
    if [ "${4:-0}" = 2 ]; then keep_guard "$d" "$d/.sums" "başarısız klasöründe ($d)" || continue; fi
    rm -rf "$d"
  done <<EOF
$list
EOF
}
prune_dirs "$OPS/releases" "$KEEP" zaman
prune_dirs "$OPS/snapshots" "$KEEP" ad 1
prune_dirs "$OPS/failed" 2 ad 2
exit 0
