<?php
/**
 * Hedef Teknoloji — anlık yayın tetiği. ops/release.mjs, yayın deposuna gönderimden hemen sonra buraya POST eder;
 * sunucu deploy.sh'yi cron'u beklemeden başlatır (DEPLOY.md §4.6).
 *
 * Tetik yalnız "yayın deposunda yeni sürüm var mı, şimdi bak" demektir: neyin kurulacağına deploy.sh'nin imza ve
 * SHA256 denetimleri karar verir. Bu yüzden sırsızdır ve isteğin gövdesi, parametreleri, başlıkları HİÇBİR davranışı
 * etkilemez (okunmaz). Kötüye kullanıma karşı: 15 sn hız sınırı, kilit (aynı anda tek deploy.sh), sabit PATH,
 * beyaz listeli ve sıkı düzenli ortam, her argüman escapeshellarg.
 *
 * Ayar web kökünün DIŞINDA: belge kökünün bir üstündeki hedefteknoloji-ops… klasörlerinin "ortam" dosyası (deploy.sh'nin
 * cron çalışması yazar); WEBROOT'u bu belge köküyle eşleşen tek kayıt seçilir. Bayrak ($OPS/TETIK) her geçerli istekte
 * (429'da da) yazılır: deploy.sh çalışıyorsa bitince bir tur daha yapar; komut çalıştırma işlevleri kapalıysa ya da hız
 * sınırındaysa bayrağı cron (her dakika) tüketir. Durdurma: ops klasöründe DURDUR (hat tamamen) ya da TETIK-KAPALI
 * (yalnız tetik) dosyası varsa hiçbir şey yazılmaz, hiçbir şey başlatılmaz.
 * Yanıt: 202 basladi | sirada | cron · 429 cok-sik (Retry-After) · 405 yalniz-post
 *        · 503 yapilandirilmamis | durduruldu | kapali | yazilamadi
 */

const HT_TETIK_ARALIK = 15;                              // iki tetik arası en az (sn)
const HT_TETIK_PATH = '/usr/local/bin:/usr/bin:/bin';     // başlatılan sürecin PATH'i (sabit)
const HT_TETIK_DEGER = '/^[A-Za-z0-9_.\/:@+-]{1,1024}$/D'; // ortamdaki her değer bu düzene uymalı
// deploy.sh'ye ortam olarak geçen anahtarlar (beyaz liste); BETIK ayrıca: çalıştırılacak deploy.sh'nin yolu
const HT_TETIK_GECEN = array(
  'CHANNEL', 'SITE_URL', 'WEBROOT', 'OPS', 'BACKUPS', 'BRANCH', 'REPO', 'HOME', 'RESOLVE_IP',
  'KEEP', 'MIN_FILES', 'MAX_DL_MB', 'MAX_UNPACK_MB', 'MAX_ENTRIES', 'RESERVE_MB', 'LOCK_STUCK_MIN', 'BACKUP_STUCK_MIN', 'GIT_TIMEOUT',
);
const HT_TETIK_SAYISAL = array('KEEP', 'MIN_FILES', 'MAX_DL_MB', 'MAX_UNPACK_MB', 'MAX_ENTRIES', 'RESERVE_MB', 'LOCK_STUCK_MIN', 'BACKUP_STUCK_MIN', 'GIT_TIMEOUT');
const HT_TETIK_ZORUNLU = array('CHANNEL', 'SITE_URL', 'WEBROOT', 'OPS', 'BACKUPS', 'BRANCH', 'REPO', 'HOME', 'BETIK');

@header_remove('X-Powered-By');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Robots-Tag: noindex, nofollow');
header('X-Content-Type-Options: nosniff');

function ht_tetik_yanit($kod, $durum)
{
  http_response_code($kod);
  echo json_encode(array('ok' => $kod < 300, 'durum' => $durum));
  exit;
}

// $OPS/ortam → doğrulanmış anahtar/değerler; tek bir kusur (bilinmeyen anahtar, tekrar, düzen dışı değer) → null
function ht_tetik_ortam_oku($dosya)
{
  if (!@is_file($dosya)) return null;
  $raw = @file_get_contents($dosya, false, null, 0, 8192);
  if (!is_string($raw) || $raw === '' || strlen($raw) >= 8192) return null;
  $izinli = array_merge(HT_TETIK_GECEN, array('BETIK'));
  $o = array();
  foreach (explode("\n", rtrim($raw, "\n")) as $satir) {
    if ($satir !== '' && $satir[0] === '#') continue;
    if (!preg_match('/^([A-Z_]{1,32})=(.*)$/sD', $satir, $m)) return null;
    if (!in_array($m[1], $izinli, true) || isset($o[$m[1]]) || !preg_match(HT_TETIK_DEGER, $m[2])) return null;
    $o[$m[1]] = $m[2];
  }
  foreach (HT_TETIK_ZORUNLU as $k) {
    if (!isset($o[$k])) return null;
  }
  if ($o['CHANNEL'] !== 'live' && $o['CHANNEL'] !== 'staging') return null;
  if (!preg_match('#^https?://#', $o['SITE_URL'])) return null;
  foreach (array('WEBROOT', 'OPS', 'BACKUPS', 'HOME', 'BETIK') as $k) {
    if ($o[$k][0] !== '/') return null;
  }
  foreach (HT_TETIK_SAYISAL as $k) {
    if (isset($o[$k]) && !preg_match('/^[0-9]{1,9}$/D', $o[$k])) return null;
  }
  if (basename($o['BETIK']) !== 'deploy.sh' || !@is_file($o['BETIK'])) return null;
  return $o;
}

// Bu sitenin ops klasörü: belge kökünün bir üstündeki hedefteknoloji-ops* içinde, WEBROOT'u bu belge kökü ve OPS'u
// o klasörün kendisi olan TEK kayıt (hiç yoksa ya da birden fazlaysa null)
function ht_tetik_ops_bul()
{
  $belge = (string) ($_SERVER['DOCUMENT_ROOT'] ?? '');
  $kok = $belge !== '' ? @realpath($belge) : false;
  if (!is_string($kok) || $kok === '/') return null;
  $dirs = @glob(dirname($kok) . '/hedefteknoloji-ops*', GLOB_ONLYDIR | GLOB_NOSORT);
  if (!is_array($dirs)) return null;
  $bulunan = array();
  foreach ($dirs as $d) {
    $o = ht_tetik_ortam_oku($d . '/ortam');
    if ($o === null) continue;
    $d = @realpath($d);
    if (@realpath($o['WEBROOT']) !== $kok || !is_string($d) || @realpath($o['OPS']) !== $d) continue;
    if (@realpath(dirname($o['BETIK'])) !== $d) continue;                     // yalnız bu ops klasöründeki deploy.sh
    $o['OPS_GERCEK'] = $d;
    $bulunan[] = $o;
  }
  return count($bulunan) === 1 ? $bulunan[0] : null;
}

// Hız sınırı ($OPS/tetik.son, kilitli): izin varsa zamanı yazar ve 0; yoksa beklenecek saniye; yazılamıyorsa -1
function ht_tetik_hiz($ops)
{
  $fh = @fopen($ops . '/tetik.son', 'c+');
  if (!$fh) return -1;
  @flock($fh, LOCK_EX);
  $son = (float) trim((string) stream_get_contents($fh));
  $simdi = microtime(true);
  $kalan = HT_TETIK_ARALIK - ($simdi - $son);
  // saat geri alındıysa (son tetik 5 sn'den fazla "gelecekte") kalıcı kilitlenme olmasın
  if ($son > 0 && $kalan > 0 && $son <= $simdi + 5) {
    flock($fh, LOCK_UN);
    fclose($fh);
    return max(1, (int) ceil($kalan));
  }
  $ok = ftruncate($fh, 0) && rewind($fh) && fwrite($fh, sprintf("%.3f\n", $simdi)) !== false;
  fflush($fh);
  flock($fh, LOCK_UN);
  fclose($fh);
  return $ok ? 0 : -1;
}

// deploy.sh şu an çalışıyor mu? (flock yolu: $OPS/.kilit · flock'suz sunucu: $OPS/.kilit.d/pid)
function ht_tetik_kilitli($ops)
{
  if (@is_dir($ops . '/.kilit.d')) {
    $pid = (int) @file_get_contents($ops . '/.kilit.d/pid', false, null, 0, 64);
    if ($pid <= 1) return true;                                   // kilit yeni alındı, kayıt henüz yazılmadı
    if (function_exists('posix_kill')) return @posix_kill($pid, 0) || (function_exists('posix_get_last_error') && posix_get_last_error() === 1);
    if (@is_dir('/proc/self')) return @file_exists('/proc/' . $pid);
    return true;                                                  // bilinemiyor: bayrak kalır, çalışma ya da cron alır
  }
  $fh = @fopen($ops . '/.kilit', 'r');
  if (!$fh) return false;
  $serbest = @flock($fh, LOCK_EX | LOCK_NB);
  if ($serbest) @flock($fh, LOCK_UN);
  @fclose($fh);
  return !$serbest;
}

function ht_tetik_islev($ad)
{
  if (!function_exists($ad)) return false;
  $kapali = array_map('trim', explode(',', strtolower((string) ini_get('disable_functions'))));
  return !in_array($ad, $kapali, true);
}

// deploy.sh'yi arka planda, istekten bağımsız başlatır. true: başlatıldı · false: denendi, olmadı · null: işlev yok
function ht_tetik_baslat($o)
{
  $islevler = array_values(array_filter(array('proc_open', 'exec', 'shell_exec', 'popen'), 'ht_tetik_islev'));
  if (!$islevler) return null;
  $path = HT_TETIK_PATH;
  $ortam = array('TETIK=1');
  foreach (HT_TETIK_GECEN as $k) {
    if (isset($o[$k])) $ortam[] = $k . '=' . $o[$k];
  }
  // Test kancası (yalnız ops/test-deploy.sh): PHP'nin yerleşik geliştirme sunucusunda (php -S) ve HEDEF_TETIK_TEST=1
  // ile deploy.sh'nin test kancaları ve PATH (sahte uapi) sürecin kendi ortamından geçer. Üretimde (LiteSpeed, FPM,
  // CGI) hiç çalışmaz; istekten (başlık, gövde) hiçbir şey okunmaz.
  if (PHP_SAPI === 'cli-server' && getenv('HEDEF_TETIK_TEST', true) === '1') {
    foreach (array('TEST_SHA', 'TEST_TARBALL', 'TEST_RELEASE_DIR', 'TEST_DL_URL', 'TEST_LOCK_SLEEP', 'TEST_MOVE_SLEEP', 'PAUSE', 'SETTLE', 'PATH') as $k) {
      $v = getenv($k, true);
      if (!is_string($v) || !preg_match(HT_TETIK_DEGER, $v)) continue;
      if ($k === 'PATH') $path = $v;
      else $ortam[] = $k . '=' . $v;
    }
  }
  array_unshift($ortam, 'PATH=' . $path);
  $args = implode(' ', array_map('escapeshellarg', $ortam));
  // setsid: yeni oturum (PHP süreci/grubu sonlansa da sürer); yoksa nohup. Ortam yalnız yukarıdaki liste (env -i).
  // Çıktı yok, hata çıktısı ops'taki tetik.hata'ya. PHP'nin açık tanımlayıcıları (sunucuya bağlantı soketi) devralınmaz:
  // deploy.sh'den önce 3–255 kapatılır — yoksa yanıt, deploy.sh bitene kadar açık kalabilirdi.
  $kapat = 'i=3; while [ "$i" -lt 256 ]; do eval "exec $i>&-"; i=$((i+1)); done; exec /bin/bash "$0"';
  $cmd = 'PATH=' . escapeshellarg($path) . '; export PATH; cd / || exit 1; '
    . 'if command -v setsid >/dev/null 2>&1; then R=setsid; else R=nohup; fi; '
    . '$R env -i ' . $args . ' /bin/bash -c ' . escapeshellarg($kapat) . ' ' . escapeshellarg($o['BETIK'])
    . ' </dev/null >/dev/null 2>>' . escapeshellarg($o['OPS_GERCEK'] . '/tetik.hata') . ' &';
  // kabuk hemen döner (iş arka planda): beklenen tek şey onun çıkış kodu
  foreach ($islevler as $f) {
    if ($f === 'proc_open') {
      $bos = array(0 => array('file', '/dev/null', 'r'), 1 => array('file', '/dev/null', 'w'), 2 => array('file', '/dev/null', 'w'));
      $p = @proc_open($cmd, $bos, $pipes, '/');
      if (is_resource($p) && proc_close($p) === 0) return true;
    } elseif ($f === 'exec') {
      $cikti = array();
      $rc = 1;
      @exec($cmd, $cikti, $rc);
      if ($rc === 0) return true;
    } elseif ($f === 'shell_exec') {
      if (trim((string) @shell_exec($cmd . ' echo ok')) === 'ok') return true;
    } else {
      $h = @popen($cmd, 'r');
      if ($h && pclose($h) === 0) return true;
    }
  }
  return false;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
  header('Allow: POST');
  ht_tetik_yanit(405, 'yalniz-post');
}
$o = ht_tetik_ops_bul();
if ($o === null) ht_tetik_yanit(503, 'yapilandirilmamis');
$ops = $o['OPS_GERCEK'];
// Durdurma anahtarları (Dosya Yöneticisi'nden boş dosya; DEPLOY.md §5, §4.6): bayrak, hız kaydı, süreç — hiçbiri
if (@file_exists($ops . '/DURDUR')) ht_tetik_yanit(503, 'durduruldu');
if (@file_exists($ops . '/TETIK-KAPALI')) ht_tetik_yanit(503, 'kapali');
// Bayrak hız sınırından ÖNCE: yazması ucuz, tekrarı zararsız; hız sınırı yalnız yeni süreç başlatmayı sınırlar — 429'da da
// süren çalışma çıkışta bayrağı görüp tek ek tur yapar (art arda iki yayın). Bayrak önce yazılır, kilit sonra sınanır:
// deploy.sh kilidi bırakıp bayrağa bakar; hangi sırayla olursa olsun tetik kaybolmaz
if (@file_put_contents($ops . '/TETIK', gmdate('c') . "\n") === false) ht_tetik_yanit(503, 'yazilamadi');
$bekle = ht_tetik_hiz($ops);
if ($bekle < 0) ht_tetik_yanit(503, 'yazilamadi');
if ($bekle > 0) {
  header('Retry-After: ' . $bekle);
  ht_tetik_yanit(429, 'cok-sik');
}
if (!ht_tetik_islev('proc_open') && !ht_tetik_islev('exec') && !ht_tetik_islev('shell_exec') && !ht_tetik_islev('popen')) {
  ht_tetik_yanit(202, 'cron');
}
if (ht_tetik_kilitli($ops)) ht_tetik_yanit(202, 'sirada');
$sonuc = ht_tetik_baslat($o);
if ($sonuc !== true) {
  error_log('[hedef-tetik] deploy.sh başlatılamadı — bayrak bırakıldı, cron alır');
  ht_tetik_yanit(202, 'cron');
}
ht_tetik_yanit(202, 'basladi');
