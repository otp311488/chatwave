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
    file_put_contents('/var/www/api/auth_log.txt', "Database connected: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
} catch (PDOException $e) {
    $response = ['status' => 'error', 'message' => 'Database connection failed: ' . $e->getMessage()];
    file_put_contents('/var/www/api/auth_log.txt', "Error: " . json_encode($response) . "\n---\n", FILE_APPEND);
    echo json_encode($response);
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
        $response = ['status' => 'error', 'message' => 'No session ID provided'];
        file_put_contents('/var/www/api/auth_log.txt', "Error: " . json_encode($response) . "\n---\n", FILE_APPEND);
        sendResponse($response, 401);
    }
    $stmt = $pdo->prepare('SELECT user_id FROM sessions WHERE session_id = ? AND expires_at > NOW()');
    $stmt->execute([$session_id]);
    $session = $stmt->fetch(PDO::FETCH_ASSOC);
    if (!$session) {
        $response = ['status' => 'error', 'message' => 'Invalid or expired session'];
        file_put_contents('/var/www/api/auth_log.txt', "Error: Session ID not found: $session_id\n---\n", FILE_APPEND);
        sendResponse($response, 401);
    }
    return $session['user_id'];
}

// Parse input
$input = json_decode(file_get_contents('php://input'), true) ?? [];
$action = $_SERVER['REQUEST_METHOD'] === 'GET' ? ($_GET['action'] ?? '') : ($input['action'] ?? $_GET['action'] ?? '');
$session_id = $_SERVER['HTTP_SESSION_ID'] ?? '';

if (empty($action)) {
    sendResponse(['status' => 'error', 'message' => 'No action specified'], 400);
}

if (!$session_id && $action !== 'delete_account') {
    sendResponse(['status' => 'error', 'message' => 'Session-ID header missing'], 401);
}

$user_id = $action !== 'delete_account' ? verifySession($pdo, $session_id) : null;

// Handle endpoints
switch ($action) {
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

        $stmt = $pdo->prepare('SELECT id, username, email, mobile_number, cnic FROM users WHERE id = ?');
        $stmt->execute([$requested_user_id]);
        $user = $stmt->fetch(PDO::FETCH_ASSOC);

        if ($user) {
            sendResponse(['status' => 'success', 'user' => $user]);
        } else {
            sendResponse(['status' => 'error', 'message' => 'User not found'], 404);
        }
        break;

    case 'update_user_info':
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        $field = $input['field'] ?? '';
        $value = $input['value'] ?? '';
        $requested_user_id = $input['user_id'] ?? '';

        if (!$requested_user_id || !$field || !$value) {
            sendResponse(['status' => 'error', 'message' => 'User ID, field, and value required'], 400);
        }
        if ($requested_user_id != $user_id) {
            sendResponse(['status' => 'error', 'message' => 'Unauthorized access'], 403);
        }

        $allowed_fields = ['email', 'mobile_number', 'cnic'];
        if (!in_array($field, $allowed_fields)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid field'], 400);
        }

        if ($field === 'email' && !filter_var($value, FILTER_VALIDATE_EMAIL)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid email format'], 400);
        }
        if ($field === 'mobile_number' && !preg_match('/^\+[1-9][0-9]{1,14}$/', $value)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid mobile number format (e.g., +923286687033)'], 400);
        }
        if ($field === 'cnic' && !preg_match('/^[a-zA-Z0-9-]{3,50}$/', $value)) {
            sendResponse(['status' => 'error', 'message' => 'CNIC must be 3-50 alphanumeric characters or hyphens'], 400);
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
        $requested_user_id = $input['user_id'] ?? '';

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
            sendResponse(['status' => 'error', 'message' => 'Failed to delete account: ' . $e->getMessage()], 500);
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
        $wallets = $stmt->fetchAll(PDO::FETCH_ASSOC);

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
        $payments = $stmt->fetchAll(PDO::FETCH_ASSOC);

        sendResponse(['status' => 'success', 'payments' => $payments]);
        break;

    default:
        sendResponse(['status' => 'error', 'message' => 'Invalid action'], 400);
}

ob_end_flush();
?>