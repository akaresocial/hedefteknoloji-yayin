<?php
/** Minimal authenticated SMTP client for hosts where PHP mail() is disabled. */

if (!defined('HT_SMTP_CLIENT')) {
  define('HT_SMTP_CLIENT', 1);

  function ht_smtp_env($name, $fallback = '') {
    if (defined($name)) return constant($name);
    $value = getenv($name);
    return $value === false ? $fallback : $value;
  }

  function ht_smtp_config() {
    $host = trim((string) ht_smtp_env('FORM_SMTP_HOST'));
    $encryption = strtolower(trim((string) ht_smtp_env('FORM_SMTP_ENCRYPTION', 'ssl')));
    if (!in_array($encryption, array('ssl', 'tls', 'none'), true)) $encryption = 'ssl';
    $defaultPort = $encryption === 'ssl' ? 465 : 587;

    return array(
      'host' => $host,
      'port' => max(1, (int) ht_smtp_env('FORM_SMTP_PORT', $defaultPort)),
      'encryption' => $encryption,
      'username' => trim((string) ht_smtp_env('FORM_SMTP_USERNAME')),
      'password' => (string) ht_smtp_env('FORM_SMTP_PASSWORD'),
      'from_email' => strtolower(trim((string) ht_smtp_env('FORM_SMTP_FROM', ht_smtp_env('FORM_SMTP_USERNAME')))),
      'from_name' => trim((string) ht_smtp_env('FORM_SMTP_FROM_NAME', 'Hedef Teknoloji')),
      'timeout' => max(5, (int) ht_smtp_env('FORM_SMTP_TIMEOUT', 15)),
    );
  }

  function ht_smtp_is_configured($config = null) {
    if (!is_array($config)) $config = ht_smtp_config();
    return !empty($config['host']) && !empty($config['username']) && $config['password'] !== ''
      && function_exists('filter_var') && filter_var($config['from_email'], FILTER_VALIDATE_EMAIL);
  }

  function ht_smtp_header_text($value) {
    return trim(str_replace(array("\r", "\n"), '', (string) $value));
  }

  function ht_smtp_encoded_header($value) {
    return '=?UTF-8?B?' . base64_encode(ht_smtp_header_text($value)) . '?=';
  }

  function ht_smtp_read_response($socket) {
    $response = '';
    $code = 0;
    for ($i = 0; $i < 100; $i++) {
      $line = @fgets($socket, 1024);
      if ($line === false) break;
      $response .= $line;
      if (preg_match('/^(\d{3})([ -])/', $line, $matches)) {
        $code = (int) $matches[1];
        if ($matches[2] === ' ') break;
      }
    }
    return array('code' => $code, 'message' => trim($response));
  }

  function ht_smtp_expect($socket, $expectedCodes, $fallbackError) {
    $response = ht_smtp_read_response($socket);
    $expectedCodes = is_array($expectedCodes) ? $expectedCodes : array($expectedCodes);
    if (!in_array($response['code'], $expectedCodes, true)) {
      return array('ok' => false, 'error' => $fallbackError . ' (SMTP ' . (int) $response['code'] . ')');
    }
    return array('ok' => true, 'response' => $response);
  }

  function ht_smtp_command($socket, $command, $expectedCodes, $fallbackError) {
    if (@fwrite($socket, $command . "\r\n") === false) {
      return array('ok' => false, 'error' => 'SMTP sunucusuna veri gönderilemedi.');
    }
    return ht_smtp_expect($socket, $expectedCodes, $fallbackError);
  }

  function ht_smtp_tls_method() {
    if (defined('STREAM_CRYPTO_METHOD_TLS_CLIENT')) return STREAM_CRYPTO_METHOD_TLS_CLIENT;
    $method = 0;
    if (defined('STREAM_CRYPTO_METHOD_TLSv1_2_CLIENT')) $method |= STREAM_CRYPTO_METHOD_TLSv1_2_CLIENT;
    if (defined('STREAM_CRYPTO_METHOD_TLSv1_1_CLIENT')) $method |= STREAM_CRYPTO_METHOD_TLSv1_1_CLIENT;
    if (defined('STREAM_CRYPTO_METHOD_TLSv1_0_CLIENT')) $method |= STREAM_CRYPTO_METHOD_TLSv1_0_CLIENT;
    return $method;
  }

  function ht_smtp_message_id($fromEmail) {
    $domain = substr(strrchr((string) $fromEmail, '@'), 1);
    if ($domain === false || $domain === '') $domain = 'hedefteknolojibilisim.com';
    try {
      $id = bin2hex(random_bytes(12));
    } catch (Throwable $e) {
      $id = str_replace('.', '', uniqid('', true));
    }
    return '<' . $id . '@' . $domain . '>';
  }

  function ht_smtp_send_message($to, $subjectText, $message, $replyTo = '', $htmlMessage = '') {
    $config = ht_smtp_config();
    if (!ht_smtp_is_configured($config)) {
      return array('ok' => false, 'error' => 'SMTP hesabı yapılandırılmamış.');
    }
    if (!filter_var($to, FILTER_VALIDATE_EMAIL)) {
      return array('ok' => false, 'error' => 'Geçersiz alıcı e-posta adresi.');
    }

    $sslContext = array(
      'ssl' => array(
        'verify_peer' => true,
        'verify_peer_name' => true,
        'allow_self_signed' => false,
        'peer_name' => $config['host'],
        'SNI_enabled' => true,
      ),
    );
    $context = stream_context_create($sslContext);
    $scheme = $config['encryption'] === 'ssl' ? 'ssl' : 'tcp';
    $remote = $scheme . '://' . $config['host'] . ':' . (int) $config['port'];
    $errno = 0;
    $errstr = '';
    $socket = @stream_socket_client(
      $remote,
      $errno,
      $errstr,
      $config['timeout'],
      STREAM_CLIENT_CONNECT,
      $context
    );
    if (!$socket) {
      return array('ok' => false, 'error' => 'SMTP sunucusuna bağlanılamadı (' . (int) $errno . ').');
    }

    @stream_set_timeout($socket, $config['timeout']);
    $result = ht_smtp_expect($socket, 220, 'SMTP sunucusu bağlantıyı kabul etmedi.');
    if (!$result['ok']) { @fclose($socket); return $result; }

    $clientHost = isset($_SERVER['HTTP_HOST']) ? preg_replace('/[^a-z0-9.\-]/i', '', $_SERVER['HTTP_HOST']) : 'hedefteknolojibilisim.com';
    if ($clientHost === '') $clientHost = 'hedefteknolojibilisim.com';
    $result = ht_smtp_command($socket, 'EHLO ' . $clientHost, 250, 'SMTP sunucusu EHLO isteğini reddetti.');
    if (!$result['ok']) { @fclose($socket); return $result; }

    if ($config['encryption'] === 'tls') {
      $result = ht_smtp_command($socket, 'STARTTLS', 220, 'SMTP sunucusu güvenli bağlantıyı başlatamadı.');
      if (!$result['ok']) { @fclose($socket); return $result; }
      $cryptoMethod = ht_smtp_tls_method();
      if (!$cryptoMethod || @stream_socket_enable_crypto($socket, true, $cryptoMethod) !== true) {
        @fclose($socket);
        return array('ok' => false, 'error' => 'SMTP TLS bağlantısı kurulamadı.');
      }
      $result = ht_smtp_command($socket, 'EHLO ' . $clientHost, 250, 'SMTP sunucusu TLS sonrası EHLO isteğini reddetti.');
      if (!$result['ok']) { @fclose($socket); return $result; }
    }

    $result = ht_smtp_command($socket, 'AUTH LOGIN', 334, 'SMTP kimlik doğrulaması başlatılamadı.');
    if (!$result['ok']) { @fclose($socket); return $result; }
    $result = ht_smtp_command($socket, base64_encode($config['username']), 334, 'SMTP kullanıcı adı kabul edilmedi.');
    if (!$result['ok']) { @fclose($socket); return $result; }
    $result = ht_smtp_command($socket, base64_encode($config['password']), 235, 'SMTP parolası kabul edilmedi.');
    if (!$result['ok']) { @fclose($socket); return $result; }

    $fromEmail = $config['from_email'];
    $result = ht_smtp_command($socket, 'MAIL FROM:<' . $fromEmail . '>', 250, 'Gönderen adresi SMTP tarafından reddedildi.');
    if (!$result['ok']) { @fclose($socket); return $result; }
    $result = ht_smtp_command($socket, 'RCPT TO:<' . $to . '>', array(250, 251), 'Alıcı adresi SMTP tarafından reddedildi.');
    if (!$result['ok']) { @fclose($socket); return $result; }
    $result = ht_smtp_command($socket, 'DATA', 354, 'SMTP sunucusu mesaj verisini kabul etmedi.');
    if (!$result['ok']) { @fclose($socket); return $result; }

    $safeReplyTo = filter_var($replyTo, FILTER_VALIDATE_EMAIL) ? strtolower($replyTo) : $fromEmail;
    $headers = array(
      'Date: ' . date(DATE_RFC2822),
      'Message-ID: ' . ht_smtp_message_id($fromEmail),
      'From: ' . ht_smtp_encoded_header($config['from_name']) . ' <' . $fromEmail . '>',
      'To: <' . strtolower($to) . '>',
      'Reply-To: <' . $safeReplyTo . '>',
      'Subject: ' . ht_smtp_encoded_header($subjectText),
      'MIME-Version: 1.0',
    );
    $normalize = function ($s) {
      $s = preg_replace("/\r\n|\r|\n/", "\r\n", (string) $s);
      return preg_replace('/^\./m', '..', $s);
    };
    $textBody = $normalize($message);
    if ((string) $htmlMessage !== '') {
      $boundary = 'hb_' . substr(md5(uniqid('', true)), 0, 20);
      $headers[] = 'Content-Type: multipart/alternative; boundary="' . $boundary . '"';
      $htmlBody = $normalize($htmlMessage);
      $mime  = '--' . $boundary . "\r\n";
      $mime .= "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n" . $textBody . "\r\n";
      $mime .= '--' . $boundary . "\r\n";
      $mime .= "Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n" . $htmlBody . "\r\n";
      $mime .= '--' . $boundary . '--';
      $payload = implode("\r\n", $headers) . "\r\n\r\n" . $mime . "\r\n.";
    } else {
      $headers[] = 'Content-Type: text/plain; charset=UTF-8';
      $headers[] = 'Content-Transfer-Encoding: 8bit';
      $payload = implode("\r\n", $headers) . "\r\n\r\n" . $textBody . "\r\n.";
    }
    $result = ht_smtp_command($socket, $payload, 250, 'SMTP sunucusu mesajı kabul etmedi.');
    if (!$result['ok']) { @fclose($socket); return $result; }

    ht_smtp_command($socket, 'QUIT', 221, 'SMTP oturumu kapatılamadı.');
    @fclose($socket);
    return array('ok' => true);
  }
}
