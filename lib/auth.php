<?php
ob_start();
ini_set('display_errors', 0);
ini_set('display_startup_errors', 0);
ini_set('log_errors', 1);
ini_set('error_log', '/var/log/php_errors.log');
error_reporting(E_ALL);

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, GET');
header('Access-Control-Allow-Headers: Content-Type, Session-ID');

// Log incoming request
file_put_contents(
    '/var/www/api/auth_log.txt',
    "Received request: Method={$_SERVER['REQUEST_METHOD']}, URI={$_SERVER['REQUEST_URI']}, " .
    "Body=" . file_get_contents('php://input') . ", Headers=" . json_encode(getallheaders()) .
    ", Time=" . date('Y-m-d H:i:s') . "\n",
    FILE_APPEND
);

// Database connection
$host = 'localhost';
$dbname = 'chat_appp';
$username = 'root';
$password = '1234Qwertyumer';

try {
    $pdo = new PDO("mysql:host=$host;dbname=$dbname", $username, $password);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE, PDO::FETCH_ASSOC);
    // Verify database connection by executing a simple query
    $pdo->query('SELECT 1');
    file_put_contents('/var/www/api/auth_log.txt', "Database connected: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
} catch (PDOException $e) {
    file_put_contents('/var/www/api/auth_log.txt', "Database connection failed: " . $e->getMessage() . "\n", FILE_APPEND);
    http_response_code(503);
    echo json_encode(['status' => 'error', 'message' => 'Service temporarily unavailable']);
    ob_end_flush();
    exit;
}

// Helper function to send JSON response
function sendResponse($data, $status = 200) {
    http_response_code($status);
    try {
        echo json_encode($data, JSON_THROW_ON_ERROR);
        file_put_contents('/var/www/api/auth_log.txt', "Response: " . json_encode($data) . "\n---\n", FILE_APPEND);
    } catch (JsonException $e) {
        $response = ['status' => 'error', 'message' => 'JSON encoding failed: ' . $e->getMessage()];
        file_put_contents('/var/www/api/auth_log.txt', "Error: " . json_encode($response) . "\n---\n", FILE_APPEND);
        echo json_encode($response);
    }
    ob_end_flush();
    exit;
}

// Helper function to verify session
function verifySession($pdo, $session_id) {
    if (empty($session_id)) {
        file_put_contents('/var/www/api/auth_log.txt', "No session ID provided, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'No session ID provided'], 401);
    }
    $stmt = $pdo->prepare('SELECT user_id, expires_at FROM sessions WHERE session_id = ?');
    $stmt->execute([$session_id]);
    $session = $stmt->fetch();
    if (!$session) {
        file_put_contents('/var/www/api/auth_log.txt', "Invalid session: session_id=$session_id, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Invalid or expired session'], 401);
    }
    if (strtotime($session['expires_at']) < time()) {
        file_put_contents('/var/www/api/auth_log.txt', "Session expired: session_id=$session_id, expires_at={$session['expires_at']}, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Session expired'], 401);
    }
    // Extend session expiry
    $new_expires_at = date('Y-m-d H:i:s', strtotime('+1 hour'));
    $stmt = $pdo->prepare('UPDATE sessions SET expires_at = ? WHERE session_id = ?');
    $stmt->execute([$new_expires_at, $session_id]);
    file_put_contents('/var/www/api/auth_log.txt', "Session validated and extended: session_id=$session_id, user_id={$session['user_id']}, expires_at=$new_expires_at, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
    return $session['user_id'];
}

// Helper function to generate OTP
function generateOTP($length = 6) {
    return str_pad(rand(0, pow(10, $length) - 1), $length, '0', STR_PAD_LEFT);
}

// Parse input
$input = json_decode(file_get_contents('php://input'), true) ?? [];
$action = $_GET['action'] ?? $input['action'] ?? '';
$session_id = $_SERVER['HTTP_SESSION_ID'] ?? '';

if (empty($action)) {
    sendResponse(['status' => 'error', 'message' => 'No action specified'], 400);
}

$user_id = ($action !== 'login' && $action !== 'signup' && $action !== 'verify_biometric' && $action !== 'send_verification_code' && $action !== 'delete_account' && $action !== 'refresh_session') ? verifySession($pdo, $session_id) : null;

// Handle endpoints
switch ($action) {
    case 'login':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        $email = trim($input['email'] ?? '');
        $password = $input['password'] ?? '';
        $biometric_enabled = filter_var($input['biometric_enabled'] ?? false, FILTER_VALIDATE_BOOLEAN);

        if (!$email || !$password) {
            sendResponse(['status' => 'error', 'message' => 'Email and password are required'], 400);
        }

        $stmt = $pdo->prepare('SELECT id, username, password, biometric_enabled, two_step_enabled FROM users WHERE email = ?');
        $stmt->execute([$email]);
        $user = $stmt->fetch();

        if ($user && password_verify($password, $user['password'])) {
            // Delete old sessions
            $stmt = $pdo->prepare('DELETE FROM sessions WHERE user_id = ?');
            $stmt->execute([$user['id']]);
            file_put_contents('/var/www/api/auth_log.txt', "Old sessions deleted for user_id={$user['id']}, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

            $session_id = bin2hex(random_bytes(16));
            $expires_at = date('Y-m-d H:i:s', strtotime('+1 hour'));
            $stmt = $pdo->prepare('INSERT INTO sessions (session_id, user_id, expires_at) VALUES (?, ?, ?)');
            $stmt->execute([$session_id, $user['id'], $expires_at]);
            file_put_contents('/var/www/api/auth_log.txt', "New session created: session_id=$session_id, user_id={$user['id']}, expires_at=$expires_at, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

            if ($biometric_enabled && !$user['biometric_enabled']) {
                $stmt = $pdo->prepare('UPDATE users SET biometric_enabled = ? WHERE id = ?');
                $stmt->execute([1, $user['id']]);
            }

            sendResponse([
                'status' => 'success',
                'session_id' => $session_id,
                'user_id' => $user['id'],
                'username' => $user['username'],
                'biometric_enabled' => $biometric_enabled || $user['biometric_enabled'],
                'two_step_enabled' => (bool)$user['two_step_enabled']
            ]);
        } else {
            sendResponse(['status' => 'error', 'message' => 'Invalid email or password'], 401);
        }
        break;

    case 'signup':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        $email = trim($input['email'] ?? '');
        $username = trim($input['username'] ?? '');
        $mobile_number = trim($input['mobile_number'] ?? '');
        $password = $input['password'] ?? '';
        $biometric_enabled = filter_var($input['biometric_enabled'] ?? false, FILTER_VALIDATE_BOOLEAN);

        if (!$email || !$username || !$mobile_number || !$password) {
            sendResponse(['status' => 'error', 'message' => 'All fields are required'], 400);
        }

        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid email format'], 400);
        }
        if (!preg_match('/^[a-zA-Z0-9]{3,50}$/', $username)) {
            sendResponse(['status' => 'error', 'message' => 'Username must be 3-50 alphanumeric characters'], 400);
        }
        if (!preg_match('/^\+[0-9]{1,14}$/', $mobile_number)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid mobile number format (e.g., +923001234567)'], 400);
        }

        $stmt = $pdo->prepare('SELECT id FROM users WHERE email = ? OR mobile_number = ?');
        $stmt->execute([$email, $mobile_number]);
        if ($stmt->fetch()) {
            sendResponse(['status' => 'error', 'message' => 'Email or mobile number already exists'], 400);
        }

        $hashed_password = password_hash($password, PASSWORD_DEFAULT);
        $stmt = $pdo->prepare('INSERT INTO users (email, username, mobile_number, password, biometric_enabled) VALUES (?, ?, ?, ?, ?)');
        try {
            $stmt->execute([$email, $username, $mobile_number, $hashed_password, $biometric_enabled ? 1 : 0]);
        } catch (PDOException $e) {
            file_put_contents('/var/www/api/auth_log.txt', "Signup error: " . $e->getMessage() . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Failed to create user'], 400);
        }

        $user_id = $pdo->lastInsertId();
        $session_id = bin2hex(random_bytes(16));
        $expires_at = date('Y-m-d H:i:s', strtotime('+1 hour'));
        $stmt = $pdo->prepare('INSERT INTO sessions (session_id, user_id, expires_at) VALUES (?, ?, ?)');
        $stmt->execute([$session_id, $user_id, $expires_at]);
        file_put_contents('/var/www/api/auth_log.txt', "New session created: session_id=$session_id, user_id=$user_id, expires_at=$expires_at, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

        sendResponse([
            'status' => 'success',
            'session_id' => $session_id,
            'user_id' => $user_id,
            'username' => $username,
            'biometric_enabled' => $biometric_enabled,
            'two_step_enabled' => false
        ]);
        break;

    case 'verify_biometric':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        $email = trim($input['email'] ?? '');

        if (!$email) {
            sendResponse(['status' => 'error', 'message' => 'Email is required'], 400);
        }

        // Fetch user by email with biometric_enabled
        $stmt = $pdo->prepare('SELECT id, username, biometric_enabled, two_step_enabled FROM users WHERE email = ? AND biometric_enabled = 1');
        $stmt->execute([$email]);
        $user = $stmt->fetch();

        if (!$user) {
            sendResponse(['status' => 'error', 'message' => 'User not found or biometric authentication not enabled'], 404);
        }

        // Delete old sessions
        $stmt = $pdo->prepare('DELETE FROM sessions WHERE user_id = ?');
        $stmt->execute([$user['id']]);
        file_put_contents('/var/www/api/auth_log.txt', "Old sessions deleted for user_id={$user['id']}, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

        // Create new session
        $session_id = bin2hex(random_bytes(16));
        $expires_at = date('Y-m-d H:i:s', strtotime('+1 hour'));
        $stmt = $pdo->prepare('INSERT INTO sessions (session_id, user_id, expires_at) VALUES (?, ?, ?)');
        $stmt->execute([$session_id, $user['id'], $expires_at]);
        file_put_contents('/var/www/api/auth_log.txt', "New session created: session_id=$session_id, user_id={$user['id']}, expires_at=$expires_at, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

        sendResponse([
            'status' => 'success',
            'session_id' => $session_id,
            'user_id' => $user['id'],
            'username' => $user['username'],
            'biometric_enabled' => true,
            'two_step_enabled' => (bool)$user['two_step_enabled']
        ]);
        break;

    case 'refresh_session':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        $email = trim($input['email'] ?? '');
        $session_id = $_SERVER['HTTP_SESSION_ID'] ?? '';

        if (!$email) {
            file_put_contents('/var/www/api/auth_log.txt', "No email provided for refresh_session, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Email is required'], 400);
        }

        try {
            // Verify user exists
            $stmt = $pdo->prepare('SELECT id, username, two_step_enabled FROM users WHERE email = ?');
            $stmt->execute([$email]);
            $user = $stmt->fetch();

            if (!$user) {
                file_put_contents('/var/www/api/auth_log.txt', "User not found for email=$email, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
                sendResponse(['status' => 'error', 'message' => 'User not found'], 404);
            }

            // Check if provided session_id is valid
            $existing_user_id = null;
            if (!empty($session_id)) {
                $stmt = $pdo->prepare('SELECT user_id, expires_at FROM sessions WHERE session_id = ?');
                $stmt->execute([$session_id]);
                $session = $stmt->fetch();
                if ($session && strtotime($session['expires_at']) > time()) {
                    $existing_user_id = $session['user_id'];
                    file_put_contents('/var/www/api/auth_log.txt', "Existing session validated: session_id=$session_id, user_id=$existing_user_id, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
                } else {
                    file_put_contents('/var/www/api/auth_log.txt', "Invalid or expired session: session_id=$session_id, expires_at=" . ($session['expires_at'] ?? 'none') . ", Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
                }
            }

            // If session is valid and matches user, extend its expiry
            if ($existing_user_id && $existing_user_id == $user['id']) {
                $new_expires_at = date('Y-m-d H:i:s', strtotime('+1 hour'));
                $stmt = $pdo->prepare('UPDATE sessions SET expires_at = ? WHERE session_id = ?');
                $stmt->execute([$new_expires_at, $session_id]);
                file_put_contents('/var/www/api/auth_log.txt', "Session extended: session_id=$session_id, user_id=$existing_user_id, expires_at=$new_expires_at, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

                sendResponse([
                    'status' => 'success',
                    'session_id' => $session_id,
                    'user_id' => $user['id'],
                    'username' => $user['username'],
                    'two_step_enabled' => (bool)$user['two_step_enabled']
                ]);
            } else {
                // Invalidate old sessions for the user
                $stmt = $pdo->prepare('DELETE FROM sessions WHERE user_id = ?');
                $stmt->execute([$user['id']]);
                file_put_contents('/var/www/api/auth_log.txt', "Old sessions deleted for user_id={$user['id']}, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

                // Create new session
                $new_session_id = bin2hex(random_bytes(16));
                $expires_at = date('Y-m-d H:i:s', strtotime('+1 hour'));
                $stmt = $pdo->prepare('INSERT INTO sessions (session_id, user_id, expires_at) VALUES (?, ?, ?)');
                $stmt->execute([$new_session_id, $user['id'], $expires_at]);
                file_put_contents('/var/www/api/auth_log.txt', "New session created: session_id=$new_session_id, user_id={$user['id']}, expires_at=$expires_at, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

                sendResponse([
                    'status' => 'success',
                    'session_id' => $new_session_id,
                    'user_id' => $user['id'],
                    'username' => $user['username'],
                    'two_step_enabled' => (bool)$user['two_step_enabled']
                ]);
            }
        } catch (Exception $e) {
            file_put_contents('/var/www/api/auth_log.txt', "Refresh session error: " . $e->getMessage() . ", Time=" . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Failed to refresh session: ' . $e->getMessage()], 500);
        }
        break;

    case 'toggle_two_step':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        $enable = filter_var($input['enable'] ?? false, FILTER_VALIDATE_BOOLEAN);

        $stmt = $pdo->prepare('UPDATE users SET two_step_enabled = ? WHERE id = ?');
        $stmt->execute([$enable ? 1 : 0, $user_id]);

        if ($enable) {
            $otp = generateOTP();
            $expires_at = date('Y-m-d H:i:s', strtotime('+5 minutes'));
            $stmt = $pdo->prepare('INSERT INTO otps (user_id, otp, expires_at) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE otp = ?, expires_at = ?');
            $stmt->execute([$user_id, $otp, $expires_at, $otp, $expires_at]);

            $stmt = $pdo->prepare('SELECT email FROM users WHERE id = ?');
            $stmt->execute([$user_id]);
            $email = $stmt->fetchColumn();

            // Log OTP to file instead of sending via email
            file_put_contents(
                '/var/www/api/otp_log.txt',
                "OTP for user_id=$user_id, email=$email: $otp, expires_at=$expires_at, Time=" . date('Y-m-d H:i:s') . "\n",
                FILE_APPEND
            );
        }

        sendResponse(['status' => 'success', 'message' => 'Two-step verification updated']);
        break;

    case 'send_verification_code':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        $email = trim($input['email'] ?? '');

        if (!$email || !filter_var($email, FILTER_VALIDATE_EMAIL)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid email'], 400);
        }

        $stmt = $pdo->prepare('SELECT id FROM users WHERE email = ?');
        $stmt->execute([$email]);
        $user = $stmt->fetch();

        if (!$user) {
            sendResponse(['status' => 'error', 'message' => 'Email not registered'], 404);
        }

        $otp = generateOTP();
        $expires_at = date('Y-m-d H:i:s', strtotime('+5 minutes'));
        $stmt = $pdo->prepare('INSERT INTO otps (user_id, otp, expires_at) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE otp = ?, expires_at = ?');
        $stmt->execute([$user['id'], $otp, $expires_at, $otp, $expires_at]);

        // Log OTP to file instead of sending via email
        file_put_contents(
            '/var/www/api/otp_log.txt',
            "OTP for user_id={$user['id']}, email=$email: $otp, expires_at=$expires_at, Time=" . date('Y-m-d H:i:s') . "\n",
            FILE_APPEND
        );

        sendResponse(['status' => 'success', 'message' => 'OTP generated and logged']);
        break;

    case 'verify_two_step_code':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        $user_id = trim($input['user_id'] ?? '');
        $code = trim($input['code'] ?? '');

        if (!$user_id || !$code) {
            sendResponse(['status' => 'error', 'message' => 'User ID and OTP code are required'], 400);
        }

        $stmt = $pdo->prepare('SELECT id FROM otps WHERE user_id = ? AND otp = ? AND expires_at > NOW()');
        $stmt->execute([$user_id, $code]);
        if ($stmt->fetch()) {
            $stmt = $pdo->prepare('DELETE FROM otps WHERE user_id = ? AND otp = ?');
            $stmt->execute([$user_id, $code]);
            sendResponse(['status' => 'success', 'message' => 'OTP verified']);
        } else {
            sendResponse(['status' => 'error', 'message' => 'Invalid or expired OTP'], 400);
        }
        break;

    case 'get_user_info':
        if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        $requested_user_id = $_GET['user_id'] ?? $user_id;

        if (!$requested_user_id) {
            sendResponse(['status' => 'error', 'message' => 'User ID required'], 400);
        }
        if ($requested_user_id != $user_id) {
            sendResponse(['status' => 'error', 'message' => 'Unauthorized access'], 403);
        }

        $stmt = $pdo->prepare('SELECT id, username, email, mobile_number, biometric_enabled, two_step_enabled FROM users WHERE id = ?');
        $stmt->execute([$requested_user_id]);
        $user = $stmt->fetch();

        if ($user) {
            sendResponse(['status' => 'success', 'user' => [
                'id' => $user['id'],
                'username' => $user['username'],
                'email' => $user['email'],
                'mobile_number' => $user['mobile_number'],
                'biometric_enabled' => (bool)$user['biometric_enabled'],
                'two_step_enabled' => (bool)$user['two_step_enabled']
            ]]);
        } else {
            sendResponse(['status' => 'error', 'message' => 'User not found'], 404);
        }
        break;

    case 'update_user_info':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        $field = trim($input['field'] ?? '');
        $value = trim($input['value'] ?? '');
        $requested_user_id = trim($input['user_id'] ?? '');

        if (!$requested_user_id || !$field || !$value) {
            sendResponse(['status' => 'error', 'message' => 'User ID, field, and value are required'], 400);
        }
        if ($requested_user_id != $user_id) {
            sendResponse(['status' => 'error', 'message' => 'Unauthorized access'], 403);
        }

        $allowed_fields = ['email', 'mobile_number'];
        if (!in_array($field, $allowed_fields)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid field'], 400);
        }

        if ($field === 'email' && !filter_var($value, FILTER_VALIDATE_EMAIL)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid email format'], 400);
        }
        if ($field === 'mobile_number' && !preg_match('/^\+[0-9]{1,14}$/', $value)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid mobile number format (e.g., +923001234567)'], 400);
        }

        $stmt = $pdo->prepare('SELECT id FROM users WHERE ' . $field . ' = ? AND id != ?');
        $stmt->execute([$value, $requested_user_id]);
        if ($stmt->fetch()) {
            sendResponse(['status' => 'error', 'message' => ucfirst($field) . ' already in use'], 400);
        }

        $stmt = $pdo->prepare("UPDATE users SET $field = ? WHERE id = ?");
        $stmt->execute([$value, $requested_user_id]);

        if ($stmt->rowCount()) {
            sendResponse(['status' => 'success', 'message' => 'User info updated']);
        } else {
            sendResponse(['status' => 'error', 'message' => 'No changes made or user not found'], 400);
        }
        break;

    case 'delete_account':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        $requested_user_id = trim($input['user_id'] ?? '');

        if (!$requested_user_id) {
            sendResponse(['status' => 'error', 'message' => 'User ID required'], 400);
        }

        $stmt = $pdo->prepare('SELECT id FROM users WHERE id = ?');
        $stmt->execute([$requested_user_id]);
        if (!$stmt->fetch()) {
            sendResponse(['status' => 'error', 'message' => 'User not found'], 404);
        }

        try {
            $pdo->beginTransaction();

            $stmt = $pdo->prepare('DELETE FROM sessions WHERE user_id = ?');
            $stmt->execute([$requested_user_id]);

            $stmt = $pdo->prepare('DELETE FROM wallets WHERE user_id = ?');
            $stmt->execute([$requested_user_id]);

            $stmt = $pdo->prepare('DELETE FROM payments WHERE sender_id = ? OR recipient_user_id = ?');
            $stmt->execute([$requested_user_id, $requested_user_id]);

            $stmt = $pdo->prepare('DELETE FROM chat_participants WHERE user_id = ?');
            $stmt->execute([$requested_user_id]);

            $stmt = $pdo->prepare('DELETE FROM users WHERE id = ?');
            $stmt->execute([$requested_user_id]);

            if ($stmt->rowCount()) {
                $pdo->commit();
                sendResponse(['status' => 'success', 'message' => 'Account deleted successfully']);
            } else {
                $pdo->rollBack();
                sendResponse(['status' => 'error', 'message' => 'User not found'], 404);
            }
        } catch (Exception $e) {
            $pdo->rollBack();
            sendResponse(['status' => 'error', 'message' => 'Failed to delete account'], 400);
        }
        break;

    case 'get_user_wallets':
        if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        if (!$user_id) {
            sendResponse(['status' => 'error', 'message' => 'User ID required'], 400);
        }

        $stmt = $pdo->prepare('SELECT id, user_id, currency, public_address, created_at FROM wallets WHERE user_id = ?');
        $stmt->execute([$user_id]);
        $wallets = $stmt->fetchAll();

        sendResponse(['status' => 'success', 'wallets' => $wallets]);
        break;

    case 'get_user_payments':
        if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        if (!$user_id) {
            sendResponse(['status' => 'error', 'message' => 'User ID required'], 400);
        }

        $stmt = $pdo->prepare('
            SELECT p.id, p.sender_id, p.recipient_user_id, p.amount, p.currency, p.created_at,
                   u1.email AS sender_email, u2.email AS receiver_email, p.chat_id
            FROM payments p
            LEFT JOIN users u1 ON p.sender_id = u1.id
            LEFT JOIN users u2 ON p.recipient_user_id = u2.id
            WHERE p.sender_id = ? OR p.recipient_user_id = ?
            ORDER BY p.created_at DESC
        ');
        $stmt->execute([$user_id, $user_id]);
        $payments = $stmt->fetchAll();

        sendResponse(['status' => 'success', 'payments' => $payments]);
        break;

    default:
        sendResponse(['status' => 'error', 'message' => 'Invalid action'], 400);
}

ob_end_flush();
?>