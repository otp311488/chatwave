<?php
ob_start();
ini_set('display_errors', 0);
ini_set('display_startup_errors', 0);
ini_set('log_errors', 1);
ini_set('error_log', '/var/log/php_errors.log');
error_reporting(E_ALL);

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET');
header('Access-Control-Allow-Headers: Content-Type, Session-ID');

// Log incoming request
file_put_contents(
    '/var/www/api/dashboard_log.txt',
    "Received request: Method={$_SERVER['REQUEST_METHOD']}, URI={$_SERVER['REQUEST_URI']}, " .
    "Headers=" . json_encode(getallheaders()) . ", Time=" . date('Y-m-d H:i:s') . "\n",
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
    file_put_contents('/var/www/api/dashboard_log.txt', "Database connected: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
} catch (PDOException $e) {
    file_put_contents('/var/www/api/dashboard_log.txt', "Database connection failed: " . $e->getMessage() . "\n", FILE_APPEND);
    sendResponse(['status' => 'error', 'message' => 'Database connection failed: ' . $e->getMessage()], 500);
}

// Helper function to send JSON response
function sendResponse($data, $status = 200) {
    http_response_code($status);
    try {
        echo json_encode($data, JSON_THROW_ON_ERROR);
        file_put_contents('/var/www/api/dashboard_log.txt', "Response: " . json_encode($data) . "\n---\n", FILE_APPEND);
    } catch (JsonException $e) {
        $response = ['status' => 'error', 'message' => 'JSON encoding failed: ' . $e->getMessage()];
        file_put_contents('/var/www/api/dashboard_log.txt', "Error: " . json_encode($response) . "\n---\n", FILE_APPEND);
        echo json_encode($response);
    }
    ob_end_flush();
    exit;
}

// Helper function to verify session
function verifySession($pdo, $session_id) {
    if (empty($session_id)) {
        file_put_contents('/var/www/api/dashboard_log.txt', "No session ID provided, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'No session ID provided'], 401);
    }
    $stmt = $pdo->prepare('SELECT user_id, expires_at FROM sessions WHERE session_id = ?');
    $stmt->execute([$session_id]);
    $session = $stmt->fetch();
    if (!$session) {
        file_put_contents('/var/www/api/dashboard_log.txt', "Invalid session: session_id=$session_id, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Invalid or expired session'], 401);
    }
    if (strtotime($session['expires_at']) < time()) {
        file_put_contents('/var/www/api/dashboard_log.txt', "Session expired: session_id=$session_id, expires_at={$session['expires_at']}, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Session expired'], 401);
    }
    // Extend session expiry
    $new_expires_at = date('Y-m-d H:i:s', strtotime('+1 hour'));
    $stmt = $pdo->prepare('UPDATE sessions SET expires_at = ? WHERE session_id = ?');
    $stmt->execute([$new_expires_at, $session_id]);
    file_put_contents('/var/www/api/dashboard_log.txt', "Session validated and extended: session_id=$session_id, user_id={$session['user_id']}, expires_at=$new_expires_at, Time=" . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
    return $session['user_id'];
}

$action = $_GET['action'] ?? '';
$session_id = $_SERVER['HTTP_SESSION_ID'] ?? '';

if (empty($action)) {
    sendResponse(['status' => 'error', 'message' => 'No action specified'], 400);
}

$user_id = verifySession($pdo, $session_id);

switch ($action) {
    case 'get_metrics':
        if ($_SERVER['REQUEST_METHOD'] !== 'GET') {
            sendResponse(['status' => 'error', 'message' => 'Method not allowed'], 405);
        }
        try {
            // Total chats the user is part of
            $stmt = $pdo->prepare('SELECT COUNT(*) FROM chat_participants WHERE user_id = ?');
            $stmt->execute([$user_id]);
            $chat_count = $stmt->fetchColumn();
    
            // Total messages sent by the user
            $stmt = $pdo->prepare('SELECT COUNT(*) FROM messages WHERE sender_id = ?');
            $stmt->execute([$user_id]);
            $messages_sent = $stmt->fetchColumn();
    
            // Total messages received by the user (in chats they participate in, excluding their own)
            $stmt = $pdo->prepare('
                SELECT COUNT(*) 
                FROM messages m
                JOIN chat_participants cp ON m.chat_id = cp.chat_id
                WHERE cp.user_id = ? AND m.sender_id != ?
            ');
            $stmt->execute([$user_id, $user_id]);
            $messages_received = $stmt->fetchColumn();
    
            // Total calls initiated by the user
            $stmt = $pdo->prepare('SELECT COUNT(*) FROM calls WHERE user_id = ?');
            $stmt->execute([$user_id]);
            $calls_sent = $stmt->fetchColumn();
    
            // Total calls received (in chats the user participates in, excluding their own)
            $stmt = $pdo->prepare('
                SELECT COUNT(*) 
                FROM calls c
                JOIN chat_participants cp ON c.chat_id = cp.chat_id
                WHERE cp.user_id = ? AND c.user_id != ?
            ');
            $stmt->execute([$user_id, $user_id]);
            $calls_received = $stmt->fetchColumn();
    
            // Total friends (distinct users in 1:1 chats)
            $stmt = $pdo->prepare('
                SELECT COUNT(DISTINCT cp2.user_id) 
                FROM chat_participants cp1
                JOIN chat_participants cp2 ON cp1.chat_id = cp2.chat_id
                JOIN chats c ON cp1.chat_id = c.id
                WHERE cp1.user_id = ? AND cp2.user_id != ? AND c.is_group = 0
            ');
            $stmt->execute([$user_id, $user_id]);
            $friends = $stmt->fetchColumn();
    
            // Total groups the user is part of
            $stmt = $pdo->prepare('
                SELECT COUNT(*) 
                FROM chat_participants cp
                JOIN chats c ON cp.chat_id = c.id
                WHERE cp.user_id = ? AND c.is_group = 1
            ');
            $stmt->execute([$user_id]);
            $groups = $stmt->fetchColumn();
    
            // Total payment amount (sent or received)
            $stmt = $pdo->prepare('SELECT SUM(amount) FROM payments WHERE sender_id = ? OR recipient_user_id = ?');
            $stmt->execute([$user_id, $user_id]);
            $total_payments = $stmt->fetchColumn() ?? 0.0;
    
            sendResponse([
                'status' => 'success',
                'metrics' => [
                    'messages_sent' => (int)$messages_sent,
                    'messages_received' => (int)$messages_received,
                    'calls_sent' => (int)$calls_sent,
                    'calls_received' => (int)$calls_received,
                    'friends' => (int)$friends,
                    'groups' => (int)$groups,
                    'total_payments' => (float)$total_payments,
                    'chat_count' => (int)$chat_count
                ]
            ]);
        } catch (PDOException $e) {
            file_put_contents('/var/www/api/dashboard_log.txt', "Database error: " . $e->getMessage() . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Failed to fetch metrics: ' . $e->getMessage()], 500);
        }
        break;

    default:
        sendResponse(['status' => 'error', 'message' => 'Invalid action'], 400);
}

ob_end_flush();
?>