<?php
/**
 * Hedef Teknoloji — iletişim ve bayilik formları.
 * İstemci: src/components/forms/LeadForm.tsx (JSON POST).
 * SMTP bilgileri ve alıcı adresi (FORM_TO) web kökünün DIŞINDAKİ ayar dosyasından okunur: yayın deposu herkese
 * açık, şifre ve kişisel adres orada olmamalı. Arama sırası: HT_FORM_CONFIG ortam değişkeni →
 * belge kökünün bir üstündeki hedefteknoloji-ayar/form-ayar.php (~/hedefteknoloji-ayar/) → api/_smtp.php (yerel geliştirme).
 * Şablon: ops/form-ayar.example.php (özel depoda). _ ile başlayan dosyalar .htaccess ile dışarıya kapalıdır.
 */

// Ayarda FORM_TO yoksa (ya da geçersizse) formların gideceği adres
const HT_FORM_TO_FALLBACK = 'info@hedefteknolojibilisim.com';
// Bu alan adları dışından (test ortamı, yerel deneme) gelen gönderimlerin konusu [TEST] ile başlar
const HT_LIVE_HOSTS = array('hedefteknolojibilisim.com', 'www.hedefteknolojibilisim.com');

date_default_timezone_set('Europe/Istanbul'); // e-postadaki "Zaman" alanı Türkiye saatiyle
header('Content-Type: application/json; charset=utf-8');
header('X-Robots-Tag: noindex, nofollow');
header('Cache-Control: no-store');

function ht_respond($status, $body)
{
  http_response_code($status);
  echo json_encode($body, JSON_UNESCAPED_UNICODE);
  exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
  ht_respond(405, array('ok' => false, 'error' => 'method'));
}

// Yalnızca aynı siteden gelen istekler (tarayıcı Origin başlığını gönderir); Host'taki port ve sondaki nokta
// (hedefteknolojibilisim.com. — sunucu aynı siteye eşler) karşılaştırmaya girmez
$host = rtrim(strtolower(preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST'] ?? '')), '.');
$origin = $_SERVER['HTTP_ORIGIN'] ?? '';
if ($origin !== '' && strtolower((string) parse_url($origin, PHP_URL_HOST)) !== $host) {
  ht_respond(403, array('ok' => false, 'error' => 'origin'));
}

$raw = file_get_contents('php://input', false, null, 0, 20000);
$data = json_decode($raw ?: '', true);
if (!is_array($data)) {
  ht_respond(400, array('ok' => false, 'error' => 'payload'));
}

// Bal küpü doluysa bot: başarılıymış gibi davran, e-posta gönderme
if (!empty($data['website'])) {
  ht_respond(200, array('ok' => true));
}
// Form 2,5 saniyeden kısa sürede doldurulamaz
if ((int) ($data['elapsed'] ?? 0) < 2500) {
  ht_respond(400, array('ok' => false, 'error' => 'too-fast'));
}

// IP yalnız REMOTE_ADDR: site Cloudflare/vekil arkasında değil; CF-Connecting-IP, X-Forwarded-For gibi başlıklar
// istemcinin elinde (sahtelenir, hız sınırı atlatılır). Cloudflare'a geçilirse bu başlığa yalnız REMOTE_ADDR
// Cloudflare'ın IP aralığındaysa güvenilmeli.
$ip = (string) ($_SERVER['REMOTE_ADDR'] ?? '0.0.0.0');

function ht_clean($value, $max = 200)
{
  if (is_array($value)) $value = implode(', ', array_slice(array_map('strval', $value), 0, 12));
  $value = str_replace(array("\r", "\0"), '', (string) $value);
  return trim(mb_substr(strip_tags($value), 0, $max));
}

$type = (($data['type'] ?? '') === 'dealer') ? 'dealer' : 'contact';
$f = array(
  'name' => ht_clean($data['name'] ?? '', 120),
  'company' => ht_clean($data['company'] ?? '', 160),
  'city' => ht_clean($data['city'] ?? '', 60),
  'phone' => ht_clean($data['phone'] ?? '', 40),
  'email' => ht_clean($data['email'] ?? '', 160),
  'subject' => ht_clean($data['subject'] ?? '', 80),
  'brands' => ht_clean($data['brands'] ?? array(), 400),
  'message' => ht_clean($data['message'] ?? '', 4000),
  'page' => ht_clean($data['page'] ?? '', 200),
  'locale' => (($data['locale'] ?? 'tr') === 'en') ? 'EN' : 'TR',
);

$errors = array();
if (mb_strlen($f['name']) < 2) $errors[] = 'name';
if (strlen(preg_replace('/\D/', '', $f['phone'])) < 10) $errors[] = 'phone';
if ($f['email'] !== '' && !filter_var($f['email'], FILTER_VALIDATE_EMAIL)) $errors[] = 'email';
if ($type === 'dealer') {
  if (mb_strlen($f['company']) < 2) $errors[] = 'company';
  if ($f['city'] === '') $errors[] = 'city';
  if ($f['email'] === '') $errors[] = 'email';
} elseif (mb_strlen($f['message']) < 5) {
  $errors[] = 'message';
}
if (empty($data['consent'])) $errors[] = 'consent';
if ($errors) {
  ht_respond(422, array('ok' => false, 'error' => 'invalid', 'fields' => array_values(array_unique($errors))));
}

function ht_form_config_path()
{
  $candidates = array();
  $env = getenv('HT_FORM_CONFIG');
  if (is_string($env) && $env !== '') $candidates[] = $env;
  $docRoot = rtrim((string) ($_SERVER['DOCUMENT_ROOT'] ?? ''), '/');
  if ($docRoot !== '') $candidates[] = dirname($docRoot) . '/hedefteknoloji-ayar/form-ayar.php';
  $candidates[] = __DIR__ . '/_smtp.php'; // yalnız yerel geliştirme (.gitignore'da)
  foreach ($candidates as $path) {
    if (@is_file($path)) return $path;
  }
  return '';
}

$config = ht_form_config_path();
if ($config !== '') require $config;
else error_log('[hedef-form] ayar dosyası bulunamadı (~/hedefteknoloji-ayar/form-ayar.php)');
require __DIR__ . '/_smtp_client.php';

// Hız sınırı — yalnız geçerli gönderimler sayılır (geçersiz istek hiçbir şey yazmaz), pencere 1 saat:
//  · kaynak başına 3 e-posta (FORM_RATE_PER_IP); kaynak = IPv4'te /24, IPv6'da /64 ağı (tek makinenin adres havuzu)
//  · toplam 30 (FORM_RATE_PER_HOUR): dolunca yalnız son saatte hiç göndermemiş kaynağın ilk gönderimi geçer, mutlak
//    sınır toplamın 3 katı — tek kaynak (ya da birkaç ağ) genel bütçeyi tüketip gerçek müşterileri kilitleyemez
//  · test ortamı (canlı alan adı dışı) ayrı sayaçta, toplam 5 (FORM_RATE_TEST_PER_HOUR): canlının bütçesine dokunmaz
// Sayaç web kökü dışındaki ayar klasöründe; süresi geçen kayıtlar her yazımda atılır (dosya büyümez).
function ht_rate_key($ip)
{
  $bin = @inet_pton($ip);
  if ($bin === false) return md5($ip);
  if (strlen($bin) === 16 && substr($bin, 0, 12) === str_repeat("\0", 10) . "\xff\xff") $bin = substr($bin, 12); // ::ffff:a.b.c.d
  return md5(strlen($bin) === 4 ? substr($bin, 0, 3) : substr($bin, 0, 8));
}
function ht_rate_file($config, $live)
{
  $name = $live ? 'form-hiz.json' : 'form-hiz-test.json';
  $dir = ($config !== '' && dirname($config) !== __DIR__) ? dirname($config) : '';
  if ($dir !== '' && @is_dir($dir) && @is_writable($dir)) return $dir . '/' . $name;
  return rtrim(sys_get_temp_dir(), '/') . '/ht_' . str_replace('-', '_', $name);
}
function ht_rate_take($file, $key, $perKey, $perHour)
{
  $fh = @fopen($file, 'c+');
  if (!$fh) return true; // sayaç açılamıyorsa gerçek müşterinin formu kilitlenmesin
  @flock($fh, LOCK_EX);
  $now = time();
  $state = json_decode((string) stream_get_contents($fh), true);
  if (!is_array($state)) $state = array();
  $all = array();
  foreach ((array) ($state['g'] ?? array()) as $t) {
    if ((int) $t > $now - 3600) $all[] = (int) $t;
  }
  $per = array();
  foreach ((array) ($state['ip'] ?? array()) as $k => $list) {
    foreach ((array) $list as $t) {
      if ((int) $t > $now - 3600) $per[$k][] = (int) $t;
    }
  }
  $mine = count($per[$key] ?? array());
  $ok = $mine < $perKey && (count($all) < $perHour || ($mine === 0 && count($all) < 3 * $perHour));
  if ($ok) {
    $all[] = $now;
    $per[$key][] = $now;
  }
  ftruncate($fh, 0);
  rewind($fh);
  fwrite($fh, json_encode(array('g' => $all, 'ip' => (object) $per)));
  fflush($fh);
  flock($fh, LOCK_UN);
  fclose($fh);
  return $ok;
}
$live = in_array($host, HT_LIVE_HOSTS, true);
$perKey = max(1, (int) ht_smtp_env('FORM_RATE_PER_IP', 3));
$perHour = $live ? max(1, (int) ht_smtp_env('FORM_RATE_PER_HOUR', 30)) : max(1, (int) ht_smtp_env('FORM_RATE_TEST_PER_HOUR', 5));
if (!ht_rate_take(ht_rate_file($config, $live), ht_rate_key($ip), $perKey, $perHour)) {
  ht_respond(429, array('ok' => false, 'error' => 'rate'));
}

$to = trim((string) ht_smtp_env('FORM_TO', HT_FORM_TO_FALLBACK));
if (!filter_var($to, FILTER_VALIDATE_EMAIL)) $to = HT_FORM_TO_FALLBACK;
$title = $type === 'dealer' ? 'Bayilik başvurusu' : 'İletişim formu';
$subject = ($live ? '' : '[TEST] ')
  . $title . ' — ' . $f['name'] . ($f['company'] !== '' ? ' (' . $f['company'] . ')' : '');

$labels = array(
  'name' => 'Ad soyad',
  'company' => 'Firma',
  'city' => 'Şehir',
  'phone' => 'Telefon',
  'email' => 'E-posta',
  'subject' => 'Konu',
  'brands' => 'Markalar',
  'message' => 'Mesaj',
  'page' => 'Sayfa',
  'locale' => 'Dil',
);
$rows = array();
foreach ($labels as $key => $label) {
  if ($f[$key] !== '') $rows[$label] = $f[$key];
}
$rows['IP'] = $ip;
$rows['Zaman'] = date('d.m.Y H:i');

$text = $title . "\n\n";
$html = '<h2 style="font-family:Arial,sans-serif;color:#253034">' . htmlspecialchars($title) . '</h2><table cellpadding="8" style="font-family:Arial,sans-serif;font-size:14px;border-collapse:collapse">';
foreach ($rows as $label => $value) {
  $text .= $label . ': ' . $value . "\n";
  $html .= '<tr><th align="left" style="background:#f3f5f5;border:1px solid #d8dfe0;color:#45535a">' . htmlspecialchars($label)
    . '</th><td style="border:1px solid #d8dfe0;color:#172024">' . nl2br(htmlspecialchars($value)) . '</td></tr>';
}
$html .= '</table>';

$result = ht_smtp_send_message($to, $subject, $text, $f['email'], $html);
if (empty($result['ok'])) {
  error_log('[hedef-form] ' . ($result['error'] ?? 'bilinmeyen hata'));
  ht_respond(502, array('ok' => false, 'error' => 'mail'));
}
ht_respond(200, array('ok' => true));
