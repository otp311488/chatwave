<?php
ob_start();
ini_set('display_errors', 0);
ini_set('log_errors', 1);
ini_set('error_log', '/var/log/php_errors.log');
error_reporting(E_ALL);

header('Content-Type: application/json');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: POST, GET');
header('Access-Control-Allow-Headers: Content-Type, Session-ID');

require_once 'vendor/autoload.php';
use Firebase\JWT\JWT;

// Database connection
$host = 'localhost';
$dbname = 'chat_appp';
$username = 'root';
$password = '1234Qwerty';

try {
    $pdo = new PDO("mysql:host=$host;dbname=$dbname", $username, $password);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    file_put_contents('/var/www/api/call_log.txt', "Database connected: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
} catch (PDOException $e) {
    $response = ['status' => 'error', 'message' => 'Database connection failed: ' . $e->getMessage(), 'error_code' => 'DB_CONNECTION_FAILED'];
    file_put_contents('/var/www/api/call_log.txt', "Error: " . json_encode($response) . "\n---\n", FILE_APPEND);
    http_response_code(500);
    echo json_encode($response);
    ob_end_flush();
    exit();
}

// VideoSDK credentials
$apiKey = 'a037c16c-2144-45f1-93a6-ab53142cf10e';
$secretKey = '9d1933986aececf5cf03985bd72c4de32c35cbeb86b325e0d503c95a801af439';
$videoSdkEndpoint = 'https://api.videosdk.live/v2';

// Generate VideoSDK JWT token dynamically
function generateVideoSdkToken($apiKey, $secretKey) {
    try {
        $payload = [
            'apikey' => $apiKey,
            'permissions' => ['allow_join', 'allow_mod'],
            'iat' => time(),
            'exp' => time() + 86400, // Token valid for 24 hours
        ];
        $token = JWT::encode($payload, $secretKey, 'HS256');
        file_put_contents('/var/www/api/call_log.txt', "Generated VideoSDK token: $token\n", FILE_APPEND);
        return $token;
    } catch (Exception $e) {
        $response = ['status' => 'error', 'message' => 'Failed to generate VideoSDK token: ' . $e->getMessage(), 'error_code' => 'TOKEN_GENERATION_FAILED'];
        file_put_contents('/var/www/api/call_log.txt', "Error: " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(500);
        echo json_encode($response);
        ob_end_flush();
        exit();
    }
}

// Session validation
function validate_session($pdo) {
    $session_id = $_SERVER['HTTP_SESSION_ID'] ?? '';
    file_put_contents('/var/www/api/call_log.txt', "Validating session ID: $session_id, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

    if (empty($session_id)) {
        $response = ['status' => 'error', 'message' => 'No session ID provided', 'error_code' => 'NO_SESSION_ID'];
        file_put_contents('/var/www/api/call_log.txt', "Error: " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(401);
        echo json_encode($response);
        ob_end_flush();
        exit();
    }

    try {
        $stmt = $pdo->prepare("SELECT user_id, expires_at FROM sessions WHERE session_id = ?");
        $stmt->execute([$session_id]);
        $session = $stmt->fetch(PDO::FETCH_ASSOC);

        if (!$session) {
            $response = ['status' => 'error', 'message' => 'Invalid session', 'error_code' => 'INVALID_SESSION'];
            file_put_contents('/var/www/api/call_log.txt', "Error: Session ID not found: $session_id\n---\n", FILE_APPEND);
            http_response_code(401);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }

        if (strtotime($session['expires_at']) < time()) {
            $response = ['status' => 'error', 'message' => 'Session expired', 'error_code' => 'SESSION_EXPIRED'];
            file_put_contents('/var/www/api/call_log.txt', "Error: Session expired for ID: $session_id, expires_at: {$session['expires_at']}\n---\n", FILE_APPEND);
            http_response_code(401);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }

        file_put_contents('/var/www/api/call_log.txt', "Session validated: user_id={$session['user_id']}, expires_at={$session['expires_at']}\n", FILE_APPEND);
        return (int)$session['user_id'];
    } catch (Exception $e) {
        $response = ['status' => 'error', 'message' => 'Session validation failed: ' . $e->getMessage(), 'error_code' => 'SESSION_VALIDATION_FAILED'];
        file_put_contents('/var/www/api/call_log.txt', "Error: " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(500);
        echo json_encode($response);
        ob_end_flush();
        exit();
    }
}

$action = $_GET['action'] ?? '';
$userId = validate_session($pdo);

// Poll for notifications
if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'poll_notifications') {
    try {
        $pdo->beginTransaction();

        $stmt = $pdo->prepare('
            SELECT DISTINCT cn.chat_id, cn.caller_id, cn.caller_name, cn.channel_name, cn.meeting_id, cn.token, cn.call_type, cn.call_uuid
            FROM call_notifications cn
            JOIN calls c ON cn.chat_id = c.chat_id AND c.status = ?
            WHERE cn.recipient_id = ? AND cn.status = ? AND cn.created_at > NOW() - INTERVAL 1 HOUR
        ');
        $stmt->execute(['active', $userId, 'pending']);
        $notifications = $stmt->fetchAll(PDO::FETCH_ASSOC);

        $notifications = array_map(function($n) {
            $n['chat_id'] = (int)$n['chat_id'];
            $n['caller_id'] = (int)$n['caller_id'];
            $n['call_type'] = in_array($n['call_type'], ['voice', 'video']) ? $n['call_type'] : 'voice';
            $n['call_uuid'] = $n['call_uuid'] ?? '';
            return $n;
        }, $notifications);

        if (!empty($notifications)) {
            $stmt = $pdo->prepare('UPDATE call_notifications SET status = ? WHERE recipient_id = ? AND status = ?');
            $stmt->execute(['processed', $userId, 'pending']);
        }

        $pdo->commit();

        $response = ['status' => 'success', 'notifications' => $notifications];
        file_put_contents('/var/www/api/call_log.txt', "Success: user_id=$userId, notifications_count=" . count($notifications) . ", " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(200);
        echo json_encode($response);
    } catch (Exception $e) {
        $pdo->rollBack();
        $response = ['status' => 'error', 'message' => 'Failed to poll notifications: ' . $e->getMessage(), 'error_code' => 'POLL_NOTIFICATIONS_FAILED'];
        file_put_contents('/var/www/api/call_log.txt', "Error: user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(500);
        echo json_encode($response);
    }
    ob_end_flush();
    exit();
}

// Start call
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'start_call') {
    try {
        $input = json_decode(file_get_contents('php://input'), true);
        $chatId = (int)($input['chat_id'] ?? 0);
        $callType = isset($input['call_type']) && in_array($input['call_type'], ['voice', 'video']) ? $input['call_type'] : 'voice';
        $callUUID = $input['call_uuid'] ?? bin2hex(random_bytes(16));
        $channelName = "chat_$chatId";

        if ($chatId <= 0) {
            $response = ['status' => 'error', 'message' => 'Invalid chat ID', 'error_code' => 'INVALID_CHAT_ID'];
            file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, " . json_encode($response) . "\n---\n", FILE_APPEND);
            http_response_code(400);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }

        $stmt = $pdo->prepare('SELECT 1 FROM chat_participants WHERE chat_id = ? AND user_id = ?');
        $stmt->execute([$chatId, $userId]);
        if (!$stmt->fetch()) {
            $response = ['status' => 'error', 'message' => 'User not in chat', 'error_code' => 'USER_NOT_IN_CHAT'];
            file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
            http_response_code(403);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }

        // Fetch caller username
        $stmt = $pdo->prepare('SELECT username FROM users WHERE id = ?');
        $stmt->execute([$userId]);
        $caller = $stmt->fetch(PDO::FETCH_ASSOC);
        $callerName = $caller['username'] ?? 'Unknown';

        // Generate VideoSDK token
        $videoSdkToken = generateVideoSdkToken($apiKey, $secretKey);

        // Create VideoSDK meeting
        $ch = curl_init("$videoSdkEndpoint/rooms");
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_HTTPHEADER, [
            "Authorization: $videoSdkToken",
            'Content-Type: application/json',
        ]);
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode(['customRoomId' => $channelName]));
        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $curlError = curl_error($ch);
        curl_close($ch);

        if ($httpCode != 200 || !$response) {
            $response = ['status' => 'error', 'message' => 'Failed to create VideoSDK room: HTTP ' . $httpCode . ', Error: ' . ($curlError ?: 'No response'), 'error_code' => 'VIDEOSDK_ROOM_CREATION_FAILED'];
            file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
            http_response_code($httpCode ?: 500);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }

        $roomData = json_decode($response, true);
        if (!isset($roomData['roomId'])) {
            $response = ['status' => 'error', 'message' => 'Invalid VideoSDK response: No roomId returned', 'error_code' => 'INVALID_VIDEOSDK_RESPONSE'];
            file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, user_id=$userId, Response: $response\n---\n", FILE_APPEND);
            http_response_code(500);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }
        $meetingId = $roomData['roomId'];

        // Store call in database
        $pdo->beginTransaction();
        $stmt = $pdo->prepare('DELETE FROM calls WHERE chat_id = ? AND status = ?');
        $stmt->execute([$chatId, 'active']);
        $stmt = $pdo->prepare('
            INSERT INTO calls (chat_id, user_id, channel_name, status, start_time, call_type, meeting_id, call_uuid, started_at)
            VALUES (?, ?, ?, ?, NOW(), ?, ?, ?, NOW())
        ');
        $stmt->execute([$chatId, $userId, $channelName, 'active', $callType, $meetingId, $callUUID]);
        $pdo->commit();

        // Notify recipients
        $stmt = $pdo->prepare('SELECT user_id FROM chat_participants WHERE chat_id = ? AND user_id != ?');
        $stmt->execute([$chatId, $userId]);
        $recipients = $stmt->fetchAll(PDO::FETCH_ASSOC);

        if (!empty($recipients)) {
            $pdo->beginTransaction();
            foreach ($recipients as $recipient) {
                $recipientId = (int)$recipient['user_id'];
                $stmt = $pdo->prepare('SELECT id FROM users WHERE id = ?');
                $stmt->execute([$recipientId]);
                if (!$stmt->fetch()) {
                    file_put_contents('/var/www/api/call_log.txt', "Warning: Invalid recipient_id=$recipientId for chat_id=$chatId, call_type=$callType, call_uuid=$callUUID\n", FILE_APPEND);
                    continue;
                }

                $stmt = $pdo->prepare('
                    INSERT INTO call_notifications (chat_id, caller_id, recipient_id, caller_name, channel_name, status, created_at, meeting_id, token, call_type, call_uuid)
                    VALUES (?, ?, ?, ?, ?, ?, NOW(), ?, ?, ?, ?)
                    ON DUPLICATE KEY UPDATE caller_name = ?, status = ?, created_at = NOW(), meeting_id = ?, token = ?, call_type = ?, call_uuid = ?
                ');
                $stmt->execute([
                    $chatId, $userId, $recipientId, $callerName, $channelName, 'pending', $meetingId, $videoSdkToken, $callType, $callUUID,
                    $callerName, 'pending', $meetingId, $videoSdkToken, $callType, $callUUID
                ]);
            }
            $pdo->commit();
        }

        $response = [
            'status' => 'success',
            'channel_name' => $channelName,
            'meeting_id' => $meetingId,
            'token' => $videoSdkToken,
            'uid' => (int)$userId,
            'caller_name' => $callerName,
            'call_type' => $callType,
            'call_uuid' => $callUUID
        ];
        file_put_contents('/var/www/api/call_log.txt', "Success: chat_id=$chatId, user_id=$userId, meeting_id=$meetingId, call_type=$callType, call_uuid=$callUUID, recipients_count=" . count($recipients) . ", " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(200);
        echo json_encode($response);
    } catch (Exception $e) {
        $pdo->rollBack();
        $response = ['status' => 'error', 'message' => 'Failed to start call: ' . $e->getMessage(), 'error_code' => 'START_CALL_FAILED'];
        file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(500);
        echo json_encode($response);
    }
    ob_end_flush();
    exit();
}

// Accept call
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'accept_call') {
    try {
        $input = json_decode(file_get_contents('php://input'), true);
        $chatId = (int)($input['chat_id'] ?? 0);
        $meetingId = $input['meeting_id'] ?? '';
        $callUUID = $input['call_uuid'] ?? '';
        $recipientId = $userId;

        if ($chatId <= 0 || empty($meetingId) || empty($callUUID)) {
            $response = ['status' => 'error', 'message' => 'Invalid chat ID, meeting ID, or call UUID', 'error_code' => 'INVALID_CALL_PARAMS'];
            file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, meeting_id=$meetingId, call_uuid=$callUUID, " . json_encode($response) . "\n---\n", FILE_APPEND);
            http_response_code(400);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }

        // Verify user is a participant
        $stmt = $pdo->prepare('SELECT 1 FROM chat_participants WHERE chat_id = ? AND user_id = ?');
        $stmt->execute([$chatId, $recipientId]);
        if (!$stmt->fetch()) {
            $response = ['status' => 'error', 'message' => 'User not in chat', 'error_code' => 'USER_NOT_IN_CHAT'];
            file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, user_id=$recipientId, " . json_encode($response) . "\n---\n", FILE_APPEND);
            http_response_code(403);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }

        // Verify call exists and is active
        $stmt = $pdo->prepare('SELECT call_type, channel_name, token, call_uuid FROM calls WHERE chat_id = ? AND meeting_id = ? AND call_uuid = ? AND status = ?');
        $stmt->execute([$chatId, $meetingId, $callUUID, 'active']);
        $call = $stmt->fetch(PDO::FETCH_ASSOC);
        if (!$call) {
            $response = ['status' => 'error', 'message' => 'No active call found', 'error_code' => 'NO_ACTIVE_CALL'];
            file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, meeting_id=$meetingId, call_uuid=$callUUID, user_id=$recipientId, " . json_encode($response) . "\n---\n", FILE_APPEND);
            http_response_code(404);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }

        // Update call_notifications status
        $pdo->beginTransaction();
        $stmt = $pdo->prepare('UPDATE call_notifications SET status = ? WHERE chat_id = ? AND recipient_id = ? AND meeting_id = ? AND call_uuid = ?');
        $stmt->execute(['accepted', $chatId, $recipientId, $meetingId, $callUUID]);

        // Notify caller of acceptance
        $stmt = $pdo->prepare('
            INSERT INTO call_notifications (chat_id, caller_id, recipient_id, caller_name, channel_name, status, created_at, meeting_id, token, call_type, call_uuid)
            VALUES (?, ?, ?, ?, ?, ?, NOW(), ?, ?, ?, ?)
        ');
        $callType = in_array($call['call_type'], ['voice', 'video']) ? $call['call_type'] : 'voice';
        $stmt->execute([$chatId, $recipientId, 0, 'System', $call['channel_name'], 'call_accepted', $meetingId, $call['token'], $callType, $callUUID]);
        $pdo->commit();

        $response = [
            'status' => 'success',
            'message' => 'Call accepted',
            'channel_name' => $call['channel_name'],
            'meeting_id' => $meetingId,
            'token' => $call['token'],
            'call_type' => $callType,
            'uid' => (int)$recipientId,
            'call_uuid' => $callUUID
        ];
        file_put_contents('/var/www/api/call_log.txt', "Success: chat_id=$chatId, meeting_id=$meetingId, call_uuid=$callUUID, user_id=$recipientId, call_type=$callType, " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(200);
        echo json_encode($response);
    } catch (Exception $e) {
        $pdo->rollBack();
        $response = ['status' => 'error', 'message' => 'Failed to accept call: ' . $e->getMessage(), 'error_code' => 'ACCEPT_CALL_FAILED'];
        file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, meeting_id=$meetingId, call_uuid=$callUUID, user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(500);
        echo json_encode($response);
    }
    ob_end_flush();
    exit();
}

// End call
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'end_call') {
    try {
        $input = json_decode(file_get_contents('php://input'), true);
        $chatId = (int)($input['chat_id'] ?? 0);
        $callUUID = $input['call_uuid'] ?? '';

        if ($chatId <= 0 || empty($callUUID)) {
            $response = ['status' => 'error', 'message' => 'Invalid chat ID or call UUID', 'error_code' => 'INVALID_CALL_PARAMS'];
            file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, call_uuid=$callUUID, " . json_encode($response) . "\n---\n", FILE_APPEND);
            http_response_code(400);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }

        $pdo->beginTransaction();
        $stmt = $pdo->prepare('UPDATE calls SET status = ?, end_time = NOW() WHERE chat_id = ? AND call_uuid = ? AND status = ?');
        $stmt->execute(['ended', $chatId, $callUUID, 'active']);
        $stmt = $pdo->prepare('DELETE FROM call_notifications WHERE chat_id = ? AND call_uuid = ?');
        $stmt->execute([$chatId, $callUUID]);
        $pdo->commit();

        $response = ['status' => 'success', 'message' => 'Call ended'];
        file_put_contents('/var/www/api/call_log.txt', "Success: chat_id=$chatId, call_uuid=$callUUID, user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(200);
        echo json_encode($response);
    } catch (Exception $e) {
        $pdo->rollBack();
        $response = ['status' => 'error', 'message' => 'Failed to end call: ' . $e->getMessage(), 'error_code' => 'END_CALL_FAILED'];
        file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, call_uuid=$callUUID, user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(500);
        echo json_encode($response);
    }
    ob_end_flush();
    exit();
}

// Notify call
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'notify_call') {
    try {
        $input = json_decode(file_get_contents('php://input'), true);
        $chatId = (int)($input['chat_id'] ?? 0);
        $callerName = $input['caller_name'] ?? 'Unknown';
        $channelName = $input['channel_name'] ?? "chat_$chatId";
        $meetingId = $input['meeting_id'] ?? "chat_$chatId";
        $token = $input['token'] ?? generateVideoSdkToken($apiKey, $secretKey);
        $callType = isset($input['call_type']) && in_array($input['call_type'], ['voice', 'video']) ? $input['call_type'] : 'voice';
        $callUUID = $input['call_uuid'] ?? bin2hex(random_bytes(16));

        if ($chatId <= 0) {
            $response = ['status' => 'error', 'message' => 'Invalid chat ID', 'error_code' => 'INVALID_CHAT_ID'];
            file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, call_type=$callType, " . json_encode($response) . "\n---\n", FILE_APPEND);
            http_response_code(400);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }

        // Log input for debugging
        file_put_contents('/var/www/api/call_log.txt', "Notify call input: chat_id=$chatId, caller_name=$callerName, channel_name=$channelName, meeting_id=$meetingId, call_type=$callType, call_uuid=$callUUID\n", FILE_APPEND);

        // Fetch caller username
        $stmt = $pdo->prepare('SELECT id, username FROM users WHERE id = ?');
        $stmt->execute([$userId]);
        $caller = $stmt->fetch(PDO::FETCH_ASSOC);
        if (!$caller) {
            $response = ['status' => 'error', 'message' => 'Invalid caller ID', 'error_code' => 'INVALID_CALLER_ID'];
            file_put_contents('/var/www/api/call_log.txt', "Error: caller_id=$userId, call_type=$callType, " . json_encode($response) . "\n---\n", FILE_APPEND);
            http_response_code(403);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }
        $callerName = $caller['username'] ?: $callerName;

        // Get recipients (exclude the caller)
        $stmt = $pdo->prepare('SELECT user_id FROM chat_participants WHERE chat_id = ? AND user_id != ?');
        $stmt->execute([$chatId, $userId]);
        $recipients = $stmt->fetchAll(PDO::FETCH_ASSOC);

        if (empty($recipients)) {
            $response = ['status' => 'error', 'message' => 'No recipients found for chat', 'error_code' => 'NO_RECIPIENTS_FOUND'];
            file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, user_id=$userId, call_type=$callType, " . json_encode($response) . "\n---\n", FILE_APPEND);
            http_response_code(404);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }

        $pdo->beginTransaction();
        foreach ($recipients as $recipient) {
            $recipientId = (int)$recipient['user_id'];
            $stmt = $pdo->prepare('SELECT id FROM users WHERE id = ?');
            $stmt->execute([$recipientId]);
            if (!$stmt->fetch()) {
                file_put_contents('/var/www/api/call_log.txt', "Warning: Invalid recipient_id=$recipientId for chat_id=$chatId, call_type=$callType, call_uuid=$callUUID\n", FILE_APPEND);
                continue;
            }

            $stmt = $pdo->prepare('
                INSERT INTO call_notifications (chat_id, caller_id, recipient_id, caller_name, channel_name, status, created_at, meeting_id, token, call_type, call_uuid)
                VALUES (?, ?, ?, ?, ?, ?, NOW(), ?, ?, ?, ?)
                ON DUPLICATE KEY UPDATE caller_name = ?, status = ?, created_at = NOW(), meeting_id = ?, token = ?, call_type = ?, call_uuid = ?
            ');
            $stmt->execute([
                $chatId, $userId, $recipientId, $callerName, $channelName, 'pending', $meetingId, $token, $callType, $callUUID,
                $callerName, 'pending', $meetingId, $token, $callType, $callUUID
            ]);
            file_put_contents('/var/www/api/call_log.txt', "Notification created: chat_id=$chatId, caller_id=$userId, recipient_id=$recipientId, call_type=$callType, call_uuid=$callUUID\n", FILE_APPEND);
        }
        $pdo->commit();

        $response = [
            'status' => 'success',
            'message' => 'Notification sent to recipients',
            'recipients_count' => count($recipients),
            'call_uuid' => $callUUID
        ];
        file_put_contents('/var/www/api/call_log.txt', "Success: chat_id=$chatId, user_id=$userId, meeting_id=$meetingId, call_type=$callType, call_uuid=$callUUID, recipients_count=" . count($recipients) . ", " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(200);
        echo json_encode($response);
    } catch (Exception $e) {
        $pdo->rollBack();
        $response = ['status' => 'error', 'message' => 'Failed to send notification: ' . $e->getMessage(), 'error_code' => 'NOTIFY_CALL_FAILED'];
        file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, user_id=$userId, call_type=$callType, call_uuid=$callUUID, " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(500);
        echo json_encode($response);
    }
    ob_end_flush();
    exit();
}

// Get call history
if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'get_call_history') {
    try {
        $stmt = $pdo->prepare('
            SELECT c.id, c.chat_id, c.user_id, u.username, c.channel_name, c.status, c.start_time, c.end_time,
                   ch.group_name as chat_name, c.meeting_id, c.call_type, c.call_uuid
            FROM calls c
            JOIN users u ON c.user_id = u.id
            LEFT JOIN chats ch ON c.chat_id = ch.id
            WHERE c.user_id = ?
            ORDER BY c.start_time DESC
            LIMIT 50
        ');
        $stmt->execute([$userId]);
        $calls = $stmt->fetchAll(PDO::FETCH_ASSOC);

        $calls = array_map(function($call) {
            $call['user_id'] = (int)$call['user_id'];
            $call['chat_id'] = (int)$call['chat_id'];
            $call['call_type'] = in_array($call['call_type'], ['voice', 'video']) ? $call['call_type'] : 'voice';
            $call['call_uuid'] = $call['call_uuid'] ?? '';
            return $call;
        }, $calls);

        $response = ['status' => 'success', 'calls' => $calls];
        file_put_contents('/var/www/api/call_log.txt', "Success: user_id=$userId, calls_count=" . count($calls) . ", " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(200);
        echo json_encode($response);
    } catch (Exception $e) {
        $response = ['status' => 'error', 'message' => 'Failed to fetch call history: ' . $e->getMessage(), 'error_code' => 'GET_CALL_HISTORY_FAILED'];
        file_put_contents('/var/www/api/call_log.txt', "Error: user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(500);
        echo json_encode($response);
    }
    ob_end_flush();
    exit();
}

// Get chat participants
if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'get_chat_participants') {
    try {
        $chatId = (int)($_GET['chat_id'] ?? 0);
        if ($chatId <= 0) {
            $response = ['status' => 'error', 'message' => 'Invalid chat ID', 'error_code' => 'INVALID_CHAT_ID'];
            file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
            http_response_code(400);
            echo json_encode($response);
            ob_end_flush();
            exit();
        }

        $stmt = $pdo->prepare('SELECT user_id FROM chat_participants WHERE chat_id = ?');
        $stmt->execute([$chatId]);
        $participants = $stmt->fetchAll(PDO::FETCH_ASSOC);

        $participants = array_map(function($p) {
            $p['user_id'] = (int)$p['user_id'];
            return $p;
        }, $participants);

        $response = ['status' => 'success', 'participants' => $participants];
        file_put_contents('/var/www/api/call_log.txt', "Success: chat_id=$chatId, user_id=$userId, participants_count=" . count($participants) . ", " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(200);
        echo json_encode($response);
    } catch (Exception $e) {
        $response = ['status' => 'error', 'message' => 'Failed to fetch participants: ' . $e->getMessage(), 'error_code' => 'GET_PARTICIPANTS_FAILED'];
        file_put_contents('/var/www/api/call_log.txt', "Error: chat_id=$chatId, user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(500);
        echo json_encode($response);
    }
    ob_end_flush();
    exit();
}

// Verify session
if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'verify_session') {
    try {
        $response = ['status' => 'success', 'user_id' => $userId];
        file_put_contents('/var/www/api/call_log.txt', "Success: user_id=$userId, action=verify_session, " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(200);
        echo json_encode($response);
    } catch (Exception $e) {
        $response = ['status' => 'error', 'message' => 'Failed to verify session: ' . $e->getMessage(), 'error_code' => 'VERIFY_SESSION_FAILED'];
        file_put_contents('/var/www/api/call_log.txt', "Error: user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
        http_response_code(500);
        echo json_encode($response);
    }
    ob_end_flush();
    exit();
}

// Test endpoint
if ($action === 'test') {
    $response = ['status' => 'success', 'message' => 'Test endpoint working'];
    file_put_contents('/var/www/api/call_log.txt', "Success: user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
    http_response_code(200);
    echo json_encode($response);
    ob_end_flush();
    exit();
}

$response = ['status' => 'error', 'message' => 'Invalid action', 'error_code' => 'INVALID_ACTION'];
file_put_contents('/var/www/api/call_log.txt', "Error: action=$action, user_id=$userId, " . json_encode($response) . "\n---\n", FILE_APPEND);
http_response_code(400);
echo json_encode($response);
ob_end_flush();
?>