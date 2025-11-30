<?php
ob_start();
ini_set('display_errors', 0);
ini_set('log_errors', 1);
ini_set('error_log', '/var/log/php_errors.log');
error_reporting(E_ALL);

header('Content-Type: application/json; charset=UTF-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, DELETE');
header('Access-Control-Allow-Headers: Content-Type, Session-Id, Session-ID');

// Database connection
$host = 'localhost';
$db_name = 'chat_appp';
$username = 'root';
$password = '1234Qwertyumer';

try {
    $pdo = new PDO("mysql:host=$host;dbname=$db_name", $username, $password);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    file_put_contents('/var/www/api/chat_log.txt', 'Database connected: ' . date('Y-m-d H:i:s') . PHP_EOL, FILE_APPEND);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'Database connection failed']);
    file_put_contents('/var/www/api/chat_log.txt', 'Database connection error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    exit();
}

// Session validation
function validateSession($pdo, $sessionId) {
    if (empty($sessionId)) {
        file_put_contents('/var/www/api/chat_log.txt', 'Validating session ID: empty' . PHP_EOL, FILE_APPEND);
        echo json_encode(['status' => 'error', 'message' => 'No session ID provided']);
        exit();
    }

    try {
        $stmt = $pdo->prepare('SELECT user_id, expires_at FROM sessions WHERE session_id = ?');
        $stmt->execute([$sessionId]);
        $session = $stmt->fetch(PDO::FETCH_ASSOC);

        if (!$session) {
            file_put_contents('/var/www/api/chat_log.txt', "Invalid session ID: $sessionId" . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid session']);
            exit();
        }

        if (strtotime($session['expires_at']) < time()) {
            file_put_contents('/var/www/api/chat_log.txt', "Session expired: $sessionId, expires_at: {$session['expires_at']}" . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Session expired']);
            exit();
        }

        // Extend session expiration
        $newExpiresAt = date('Y-m-d H:i:s', strtotime('+1 hour'));
        $stmt = $pdo->prepare('UPDATE sessions SET expires_at = ? WHERE session_id = ?');
        $stmt->execute([$newExpiresAt, $sessionId]);

        file_put_contents('/var/www/api/chat_log.txt', "Session validated: user_id={$session['user_id']}, expires_at=$newExpiresAt" . PHP_EOL, FILE_APPEND);
        return $session['user_id'];
    } catch (PDOException $e) {
        file_put_contents('/var/www/api/chat_log.txt', 'Session validation error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
        echo json_encode(['status' => 'error', 'message' => 'Session validation failed']);
        exit();
    }
}

// Rate limiting
function checkRateLimit($pdo, $userId, $actionType) {
    try {
        $stmt = $pdo->prepare('SELECT COUNT(*) FROM rate_limits WHERE user_id = ? AND action_type = ? AND action_time > NOW() - INTERVAL 1 MINUTE');
        $stmt->execute([$userId, $actionType]);
        $attempts = $stmt->fetchColumn();

        $limits = [
            'send_message' => 20,
            'create_chat' => 5,
            'upload_media' => 10,
            'register' => 5,
            'login' => 10,
            'update_profile' => 5,
            'set_typing' => 20,
            'set_nickname' => 10,
            'forward_message' => 10,
        ];
        $limit = $limits[$actionType] ?? 5;

        if ($attempts >= $limit) {
            file_put_contents('/var/www/api/chat_log.txt', "Rate limit exceeded: user_id=$userId, action_type=$actionType, attempts=$attempts, limit=$limit" . PHP_EOL, FILE_APPEND);
            return false;
        }

        $stmt = $pdo->prepare('INSERT INTO rate_limits (user_id, action_type, action_time) VALUES (?, ?, NOW())');
        $stmt->execute([$userId, $actionType]);
        file_put_contents('/var/www/api/chat_log.txt', "Rate limit recorded: user_id=$userId, action_type=$actionType" . PHP_EOL, FILE_APPEND);
        return true;
    } catch (PDOException $e) {
        file_put_contents('/var/www/api/chat_log.txt', 'Rate limit error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
        return true; // Allow action to proceed to avoid blocking due to DB error
    }
}

$action = $_GET['action'] ?? '';
// Get session ID case-insensitively
$sessionId = null;
$headers = getallheaders();
foreach ($headers as $key => $value) {
    if (strtolower($key) === 'session-id') {
        $sessionId = $value;
        break;
    }
}
$sessionId = $sessionId ?? ($_SERVER['HTTP_SESSION_ID'] ?? '');
file_put_contents('/var/www/api/chat_log.txt', 'Received Session-Id: ' . ($sessionId ?: 'none') . ' for action: ' . $action . ' at ' . date('Y-m-d H:i:s') . PHP_EOL, FILE_APPEND);

if ($action !== 'serve_media' && $action !== 'register' && $action !== 'login') {
    $userId = validateSession($pdo, $sessionId);
}

// Register user
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'register') {
    try {
        if (!checkRateLimit($pdo, 0, 'register')) {
            echo json_encode(['status' => 'error', 'message' => 'Too many registration attempts. Try again later.']);
            exit();
        }

        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Register invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $username = trim($input['username'] ?? '');
        $email = trim($input['email'] ?? '');
        $password = trim($input['password'] ?? '');

        if (strlen($username) < 3) {
            echo json_encode(['status' => 'error', 'message' => 'Username must be at least 3 characters']);
            exit();
        }
        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid email address']);
            exit();
        }
        if (strlen($password) < 8) {
            echo json_encode(['status' => 'error', 'message' => 'Password must be at least 8 characters']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT id FROM users WHERE username = ? OR email = ?');
        $stmt->execute([$username, $email]);
        if ($stmt->fetch()) {
            echo json_encode(['status' => 'error', 'message' => 'Username or email already taken']);
            exit();
        }

        $hashedPassword = password_hash($password, PASSWORD_BCRYPT);
        $stmt = $pdo->prepare('INSERT INTO users (username, email, password, created_at) VALUES (?, ?, ?, NOW())');
        $stmt->execute([$username, $email, $hashedPassword]);
        $userId = $pdo->lastInsertId();

        echo json_encode(['status' => 'success', 'user_id' => $userId, 'message' => 'User registered successfully']);
        file_put_contents('/var/www/api/chat_log.txt', "User registered: user_id=$userId, username=$username" . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to register user']);
        file_put_contents('/var/www/api/chat_log.txt', 'Register error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Login user
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'login') {
    try {
        if (!checkRateLimit($pdo, 0, 'login')) {
            echo json_encode(['status' => 'error', 'message' => 'Too many login attempts. Try again later.']);
            exit();
        }

        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Login invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $email = trim($input['email'] ?? '');
        $password = trim($input['password'] ?? '');

        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid email address']);
            exit();
        }
        if (empty($password)) {
            echo json_encode(['status' => 'error', 'message' => 'Password is required']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT id, username, password FROM users WHERE email = ?');
        $stmt->execute([$email]);
        $user = $stmt->fetch(PDO::FETCH_ASSOC);

        if (!$user || !password_verify($password, $user['password'])) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid email or password']);
            exit();
        }

        $stmt = $pdo->prepare('DELETE FROM sessions WHERE user_id = ?');
        $stmt->execute([$user['id']]);

        $sessionId = bin2hex(random_bytes(32));
        $expiresAt = date('Y-m-d H:i:s', strtotime('+1 hour'));
        $stmt = $pdo->prepare('INSERT INTO sessions (user_id, session_id, expires_at) VALUES (?, ?, ?)');
        $stmt->execute([$user['id'], $sessionId, $expiresAt]);

        echo json_encode([
            'status' => 'success',
            'session_id' => $sessionId,
            'user_id' => $user['id'],
            'username' => $user['username'],
            'message' => 'Login successful'
        ]);
        file_put_contents('/var/www/api/chat_log.txt', "User logged in: user_id={$user['id']}, session_id=$sessionId, expires_at=$expiresAt" . PHP_EOL, FILE_APPEND);
    } catch (Exception $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to login']);
        file_put_contents('/var/www/api/chat_log.txt', 'Login error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Logout user
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'logout') {
    try {
        $stmt = $pdo->prepare('DELETE FROM sessions WHERE session_id = ?');
        $stmt->execute([$sessionId]);

        echo json_encode(['status' => 'success', 'message' => 'Logged out successfully']);
        file_put_contents('/var/www/api/chat_log.txt', "User logged out: session_id=$sessionId" . PHP_EOL, FILE_APPEND);
    } catch (Exception $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to logout']);
        file_put_contents('/var/www/api/chat_log.txt', 'Logout error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Update user profile
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'update_profile') {
    try {
        if (!checkRateLimit($pdo, $userId, 'update_profile')) {
            echo json_encode(['status' => 'error', 'message' => 'Too many profile update requests. Try again later.']);
            exit();
        }

        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Update profile invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $username = trim($input['username'] ?? '');
        $email = trim($input['email'] ?? '');

        if (!empty($username) && strlen($username) < 3) {
            echo json_encode(['status' => 'error', 'message' => 'Username must be at least 3 characters']);
            exit();
        }
        if (!empty($email) && !filter_var($email, FILTER_VALIDATE_EMAIL)) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid email address']);
            exit();
        }

        if (!empty($username) || !empty($email)) {
            $stmt = $pdo->prepare('SELECT id FROM users WHERE (username = ? OR email = ?) AND id != ?');
            $stmt->execute([$username, $email, $userId]);
            if ($stmt->fetch()) {
                echo json_encode(['status' => 'error', 'message' => 'Username or email already taken']);
                exit();
            }
        }

        $updates = [];
        $params = [];
        if (!empty($username)) {
            $updates[] = 'username = ?';
            $params[] = $username;
        }
        if (!empty($email)) {
            $updates[] = 'email = ?';
            $params[] = $email;
        }

        if (!empty($updates)) {
            $params[] = $userId;
            $stmt = $pdo->prepare('UPDATE users SET ' . implode(', ', $updates) . ' WHERE id = ?');
            $stmt->execute($params);
        }

        echo json_encode(['status' => 'success', 'message' => 'Profile updated successfully']);
        file_put_contents('/var/www/api/chat_log.txt', "Profile updated: user_id=$userId" . PHP_EOL, FILE_APPEND);
    } catch (Exception $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to update profile']);
        file_put_contents('/var/www/api/chat_log.txt', 'Update profile error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Serve media files
if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'serve_media') {
    try {
        $fileName = basename($_GET['file'] ?? '');
        if (empty($fileName)) {
            http_response_code(400);
            echo json_encode(['status' => 'error', 'message' => 'No file specified']);
            file_put_contents('/var/www/api/chat_log.txt', 'No file specified for serve_media' . PHP_EOL, FILE_APPEND);
            exit();
        }

        $filePath = realpath('/var/www/api/Uploads/' . $fileName);
        if (!$filePath || !file_exists($filePath) || strpos($filePath, '/var/www/api/Uploads/') !== 0) {
            http_response_code(404);
            echo json_encode(['status' => 'error', 'message' => 'File not found']);
            file_put_contents('/var/www/api/chat_log.txt', "File not found: /var/www/api/Uploads/$fileName" . PHP_EOL, FILE_APPEND);
            exit();
        }

        $extension = strtolower(pathinfo($filePath, PATHINFO_EXTENSION));
        $mimeTypes = [
            'mp4' => 'video/mp4',
            'mov' => 'video/quicktime',
            'jpg' => 'image/jpeg',
            'jpeg' => 'image/jpeg',
            'png' => 'image/png',
            'gif' => 'image/gif',
            'm4a' => 'audio/mp4',
            'mp3' => 'audio/mpeg',
            'wav' => 'audio/wav',
            'pdf' => 'application/pdf',
        ];
        $contentType = $mimeTypes[$extension] ?? 'application/octet-stream';

        header('Content-Type: ' . $contentType);
        header('Accept-Ranges: bytes');
        header('Content-Length: ' . filesize($filePath));
        header('Cache-Control: no-cache');
        header('Access-Control-Allow-Origin: *');
        readfile($filePath);
        file_put_contents('/var/www/api/chat_log.txt', "Served file: $filePath, MIME: $contentType, Size: " . filesize($filePath) . ' bytes' . PHP_EOL, FILE_APPEND);
        exit();
    } catch (Exception $e) {
        http_response_code(500);
        echo json_encode(['status' => 'error', 'message' => 'Failed to serve media']);
        file_put_contents('/var/www/api/chat_log.txt', 'Serve media error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
        exit();
    }
}

// Create chat
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'create_chat') {
    try {
        if (!checkRateLimit($pdo, $userId, 'create_chat')) {
            echo json_encode(['status' => 'error', 'message' => 'Too many chat creation attempts. Try again later.']);
            exit();
        }

        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Create chat invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $isGroup = filter_var($input['is_group'] ?? false, FILTER_VALIDATE_BOOLEAN);
        $chatName = $isGroup ? trim($input['chat_name'] ?? '') : null;
        $participantIds = $input['participant_ids'] ?? [];

        if ($isGroup && (empty($chatName) || strlen($chatName) < 3)) {
            echo json_encode(['status' => 'error', 'message' => 'Group name must be at least 3 characters']);
            exit();
        }
        if (empty($participantIds)) {
            echo json_encode(['status' => 'error', 'message' => 'At least one participant required']);
            exit();
        }
        if ($isGroup && count($participantIds) < 2) {
            echo json_encode(['status' => 'error', 'message' => 'Group chats require at least two participants']);
            exit();
        }
        if (!$isGroup && count($participantIds) != 1) {
            echo json_encode(['status' => 'error', 'message' => 'One-to-one chats require exactly one participant']);
            exit();
        }

        $participantIds = array_map('intval', $participantIds);
        if (in_array($userId, $participantIds)) {
            echo json_encode(['status' => 'error', 'message' => 'Cannot include yourself as a participant']);
            exit();
        }

        $placeholders = implode(',', array_fill(0, count($participantIds), '?'));
        $stmt = $pdo->prepare("SELECT id FROM users WHERE id IN ($placeholders)");
        $stmt->execute($participantIds);
        $existingUsers = $stmt->fetchAll(PDO::FETCH_COLUMN);
        if (count($existingUsers) !== count($participantIds)) {
            echo json_encode(['status' => 'error', 'message' => 'One or more participants do not exist']);
            exit();
        }

        if (!$isGroup) {
            $otherUserId = $participantIds[0];
            $stmt = $pdo->prepare('SELECT 1 FROM blocked_users WHERE (user_id = ? AND blocked_user_id = ?) OR (user_id = ? AND blocked_user_id = ?)');
            $stmt->execute([$userId, $otherUserId, $otherUserId, $userId]);
            if ($stmt->fetch()) {
                echo json_encode(['status' => 'error', 'message' => 'Cannot create chat with a blocked user']);
                exit();
            }

            $stmt = $pdo->prepare(
                'SELECT c.id FROM chats c
                 JOIN chat_participants cp1 ON c.id = cp1.chat_id
                 JOIN chat_participants cp2 ON c.id = cp2.chat_id
                 WHERE c.is_group = 0
                 AND cp1.user_id = ? AND cp2.user_id = ?'
            );
            $stmt->execute([$userId, $otherUserId]);
            if ($existingChat = $stmt->fetch(PDO::FETCH_ASSOC)) {
                echo json_encode(['status' => 'success', 'chat_id' => $existingChat['id'], 'message' => 'Chat already exists']);
                exit();
            }
        }

        $pdo->beginTransaction();
        $stmt = $pdo->prepare('INSERT INTO chats (is_group, group_name, created_at) VALUES (?, ?, NOW())');
        $stmt->execute([$isGroup ? 1 : 0, $chatName]);
        $chatId = $pdo->lastInsertId();

        $stmt = $pdo->prepare('INSERT INTO chat_participants (chat_id, user_id) VALUES (?, ?)');
        $stmt->execute([$chatId, $userId]);
        foreach ($participantIds as $participantId) {
            $stmt->execute([$chatId, $participantId]);
        }

        $pdo->commit();

        echo json_encode(['status' => 'success', 'chat_id' => $chatId, 'message' => 'Chat created successfully']);
        file_put_contents('/var/www/api/chat_log.txt', "Chat created: chat_id=$chatId, is_group=$isGroup, name=$chatName" . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        $pdo->rollBack();
        echo json_encode(['status' => 'error', 'message' => 'Failed to create chat']);
        file_put_contents('/var/www/api/chat_log.txt', 'Create chat error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Get chats
if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'get_chats') {
    try {
        $stmt = $pdo->prepare(
            'SELECT c.id, c.is_group, c.group_name, GROUP_CONCAT(cp.user_id) as participants
             FROM chats c
             JOIN chat_participants cp ON c.id = cp.chat_id
             WHERE c.id IN (SELECT chat_id FROM chat_participants WHERE user_id = ?)
             GROUP BY c.id'
        );
        $stmt->execute([$userId]);
        $chats = $stmt->fetchAll(PDO::FETCH_ASSOC);

        $userStmt = $pdo->prepare(
            'SELECT id, username, email, verified
             FROM users
             WHERE id IN (SELECT user_id FROM chat_participants WHERE chat_id IN (SELECT chat_id FROM chat_participants WHERE user_id = ?))'
        );
        $userStmt->execute([$userId]);
        $users = $userStmt->fetchAll(PDO::FETCH_ASSOC);
        $userMap = array_column($users, null, 'id');

        $nicknameStmt = $pdo->prepare(
            'SELECT target_id, is_group, nickname
             FROM nicknames
             WHERE user_id = ?'
        );
        $nicknameStmt->execute([$userId]);
        $nicknames = $nicknameStmt->fetchAll(PDO::FETCH_ASSOC);
        $nicknameMap = [];
        foreach ($nicknames as $nickname) {
            $key = $nickname['is_group'] ? 'group_' . $nickname['target_id'] : 'user_' . $nickname['target_id'];
            $nicknameMap[$key] = $nickname['nickname'];
        }

        $result = array_map(function ($chat) use ($userMap, $nicknameMap, $userId) {
            $participants = array_map('intval', explode(',', $chat['participants']));
            $chat['participants'] = $participants;

            if ($chat['is_group']) {
                $chat['name'] = $nicknameMap['group_' . $chat['id']] ?? $chat['group_name'] ?? 'Group Chat';
            } else {
                $otherUserId = null;
                foreach ($participants as $participantId) {
                    if ($participantId != $userId) {
                        $otherUserId = $participantId;
                        break;
                    }
                }
                $chat['name'] = $nicknameMap['user_' . $otherUserId] ?? $userMap[$otherUserId]['username'] ?? $userMap[$otherUserId]['email'] ?? 'Unknown';
                $chat['other_user_id'] = $otherUserId;
                $chat['verified'] = $userMap[$otherUserId]['verified'] == 1 || $userMap[$otherUserId]['verified'] === true;
            }

            unset($chat['group_name']);
            return $chat;
        }, $chats);

        echo json_encode(['status' => 'success', 'chats' => $result]);
        file_put_contents('/var/www/api/chat_log.txt', "Fetched chats for user_id=$userId, count=" . count($result) . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to fetch chats']);
        file_put_contents('/var/www/api/chat_log.txt', 'Get chats error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Send message
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'send_message') {
    try {
        if (!checkRateLimit($pdo, $userId, 'send_message')) {
            http_response_code(429);
            echo json_encode(['status' => 'error', 'message' => 'Too many messages sent. Try again later.']);
            exit();
        }

        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Send message invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            http_response_code(400);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $chatId = filter_var($input['chat_id'] ?? 0, FILTER_VALIDATE_INT);
        $type = trim($input['type'] ?? 'text');
        $content = trim($input['content'] ?? '');
        $mediaUrl = trim($input['media_url'] ?? '');

        if ($chatId <= 0) {
            http_response_code(400);
            echo json_encode(['status' => 'error', 'message' => 'Invalid chat ID']);
            exit();
        }
        if (!in_array($type, ['text', 'image', 'video', 'voice', 'document', 'gif', 'location'])) {
            http_response_code(400);
            echo json_encode(['status' => 'error', 'message' => 'Invalid message type']);
            exit();
        }
        if ($type === 'text' && empty($content)) {
            http_response_code(400);
            echo json_encode(['status' => 'error', 'message' => 'Message content cannot be empty']);
            exit();
        }
        if ($type !== 'text' && $type !== 'location' && empty($mediaUrl)) {
            http_response_code(400);
            echo json_encode(['status' => 'error', 'message' => 'Media URL required for non-text messages']);
            exit();
        }
        if ($type !== 'text' && $type !== 'location' && !filter_var($mediaUrl, FILTER_VALIDATE_URL)) {
            http_response_code(400);
            echo json_encode(['status' => 'error', 'message' => 'Invalid media URL']);
            exit();
        }

        // Validate media file existence (except for location messages)
        if ($type !== 'text' && $type !== 'location') {
            $parsedUrl = parse_url($mediaUrl);
            $fileName = basename($parsedUrl['path']);
            $filePath = '/var/www/api/Uploads/' . $fileName;
            if (!file_exists($filePath)) {
                http_response_code(400);
                echo json_encode(['status' => 'error', 'message' => 'Media file not found on server']);
                exit();
            }
        }

        $stmt = $pdo->prepare('SELECT 1 FROM chat_participants WHERE chat_id = ? AND user_id = ?');
        $stmt->execute([$chatId, $userId]);
        if (!$stmt->fetch()) {
            http_response_code(403);
            echo json_encode(['status' => 'error', 'message' => 'You are not a participant of this chat']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT is_group, group_name FROM chats WHERE id = ?');
        $stmt->execute([$chatId]);
        $chat = $stmt->fetch(PDO::FETCH_ASSOC);
        if (!$chat) {
            http_response_code(404);
            echo json_encode(['status' => 'error', 'message' => 'Chat does not exist']);
            exit();
        }

        $stmt = $pdo->prepare(
            'SELECT bu.user_id, bu.blocked_user_id
             FROM blocked_users bu
             JOIN chat_participants cp ON bu.user_id = cp.user_id OR bu.blocked_user_id = cp.user_id
             WHERE cp.chat_id = ? AND (bu.user_id = ? OR bu.blocked_user_id = ?)'
        );
        $stmt->execute([$chatId, $userId, $userId]);
        $blocks = $stmt->fetchAll(PDO::FETCH_ASSOC);
        foreach ($blocks as $block) {
            if ($block['user_id'] == $userId || $block['blocked_user_id'] == $userId) {
                http_response_code(403);
                echo json_encode(['status' => 'error', 'message' => 'Cannot send message due to block']);
                exit();
            }
        }

        $pdo->beginTransaction();
        $stmt = $pdo->prepare(
            'INSERT INTO messages (chat_id, sender_id, type, content, media_url, created_at)
             VALUES (?, ?, ?, ?, ?, NOW())'
        );
        $stmt->execute([$chatId, $userId, $type, $content, $mediaUrl]);
        $messageId = $pdo->lastInsertId();
        $pdo->commit();

        http_response_code(200);
        echo json_encode(['status' => 'success', 'message_id' => $messageId, 'message' => 'Message sent successfully']);
        file_put_contents('/var/www/api/chat_log.txt', "Message sent: message_id=$messageId, chat_id=$chatId, user_id=$userId, type=$type, content=" . substr($content, 0, 50) . ", media_url=$mediaUrl" . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        $pdo->rollBack();
        http_response_code(500);
        echo json_encode(['status' => 'error', 'message' => 'Failed to send message']);
        file_put_contents('/var/www/api/chat_log.txt', 'Send message error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Get messages
if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'get_messages') {
    try {
        $chatId = filter_input(INPUT_GET, 'chat_id', FILTER_VALIDATE_INT);
        $limit = filter_input(INPUT_GET, 'limit', FILTER_VALIDATE_INT) ?: 50;
        $offset = filter_input(INPUT_GET, 'offset', FILTER_VALIDATE_INT) ?: 0;

        if ($chatId === false || $chatId <= 0) {
            http_response_code(400);
            echo json_encode(['status' => 'error', 'message' => 'Invalid chat ID']);
            file_put_contents('/var/www/api/chat_log.txt', "Invalid chat ID: chat_id=$chatId, user_id=$userId" . PHP_EOL, FILE_APPEND);
            exit();
        }
        if ($limit <= 0 || $offset < 0) {
            http_response_code(400);
            echo json_encode(['status' => 'error', 'message' => 'Invalid limit or offset']);
            file_put_contents('/var/www/api/chat_log.txt', "Invalid limit or offset: limit=$limit, offset=$offset, user_id=$userId" . PHP_EOL, FILE_APPEND);
            exit();
        }

        $stmt = $pdo->prepare('SELECT 1 FROM chat_participants WHERE chat_id = ? AND user_id = ?');
        $stmt->execute([$chatId, $userId]);
        if (!$stmt->fetch()) {
            http_response_code(403);
            echo json_encode(['status' => 'error', 'message' => 'You are not a participant of this chat']);
            file_put_contents('/var/www/api/chat_log.txt', "Not a participant: chat_id=$chatId, user_id=$userId" . PHP_EOL, FILE_APPEND);
            exit();
        }

        $limit = (int)$limit;
        $offset = (int)$offset;

        $stmt = $pdo->prepare(
            'SELECT m.*, u.username, u.verified, (SELECT COUNT(*) FROM message_reads mr WHERE mr.message_id = m.id) as read_count
             FROM messages m
             JOIN users u ON m.sender_id = u.id
             WHERE m.chat_id = ?
             ORDER BY m.created_at ASC
             LIMIT ? OFFSET ?'
        );
        $stmt->bindValue(1, $chatId, PDO::PARAM_INT);
        $stmt->bindValue(2, $limit, PDO::PARAM_INT);
        $stmt->bindValue(3, $offset, PDO::PARAM_INT);
        $stmt->execute();
        $messages = $stmt->fetchAll(PDO::FETCH_ASSOC);

        http_response_code(200);
        echo json_encode(['status' => 'success', 'messages' => $messages]);
        file_put_contents('/var/www/api/chat_log.txt', "Fetched messages: chat_id=$chatId, user_id=$userId, count=" . count($messages) . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        http_response_code(500);
        echo json_encode(['status' => 'error', 'message' => 'Failed to fetch messages']);
        file_put_contents('/var/www/api/chat_log.txt', 'Get messages error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Mark message as read
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'mark_read') {
    try {
        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Mark read invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $messageId = filter_var($input['message_id'] ?? 0, FILTER_VALIDATE_INT);
        if ($messageId <= 0) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid message ID']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT chat_id, sender_id FROM messages WHERE id = ?');
        $stmt->execute([$messageId]);
        $message = $stmt->fetch(PDO::FETCH_ASSOC);
        if (!$message) {
            echo json_encode(['status' => 'error', 'message' => 'Message not found']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT 1 FROM chat_participants WHERE chat_id = ? AND user_id = ?');
        $stmt->execute([$message['chat_id'], $userId]);
        if (!$stmt->fetch()) {
            echo json_encode(['status' => 'error', 'message' => 'You are not a participant of this chat']);
            exit();
        }

        $stmt = $pdo->prepare(
            'INSERT IGNORE INTO message_reads (message_id, user_id, read_at)
             VALUES (?, ?, NOW())'
        );
        $stmt->execute([$messageId, $userId]);

        echo json_encode(['status' => 'success', 'message' => 'Message marked as read']);
        file_put_contents('/var/www/api/chat_log.txt', "Message marked as read: message_id=$messageId, user_id=$userId" . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to mark message as read']);
        file_put_contents('/var/www/api/chat_log.txt', 'Mark read error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Delete message
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'delete_message') {
    try {
        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Delete message invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $messageId = filter_var($input['message_id'] ?? 0, FILTER_VALIDATE_INT);
        if ($messageId <= 0) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid message ID']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT sender_id, media_url FROM messages WHERE id = ?');
        $stmt->execute([$messageId]);
        $message = $stmt->fetch(PDO::FETCH_ASSOC);
        if (!$message) {
            echo json_encode(['status' => 'error', 'message' => 'Message not found']);
            exit();
        }

        if ($message['sender_id'] != $userId) {
            echo json_encode(['status' => 'error', 'message' => 'You can only delete your own messages']);
            exit();
        }

        if ($message['media_url']) {
            $fileName = basename($message['media_url']);
            $filePath = '/var/www/api/Uploads/' . $fileName;
            if (file_exists($filePath)) {
                unlink($filePath);
                file_put_contents('/var/www/api/chat_log.txt', "Deleted file: $filePath" . PHP_EOL, FILE_APPEND);
            }
        }

        $stmt = $pdo->prepare('DELETE FROM messages WHERE id = ?');
        $stmt->execute([$messageId]);

        echo json_encode(['status' => 'success', 'message' => 'Message deleted successfully']);
        file_put_contents('/var/www/api/chat_log.txt', "Message deleted: message_id=$messageId, user_id=$userId" . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to delete message']);
        file_put_contents('/var/www/api/chat_log.txt', 'Delete message error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Delete chat
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'delete_chat') {
    try {
        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Delete chat invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $chatId = filter_var($input['chat_id'] ?? 0, FILTER_VALIDATE_INT);
        if ($chatId <= 0) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid chat ID']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT 1 FROM chat_participants WHERE chat_id = ? AND user_id = ?');
        $stmt->execute([$chatId, $userId]);
        if (!$stmt->fetch()) {
            echo json_encode(['status' => 'error', 'message' => 'You are not a participant of this chat']);
            exit();
        }

        $pdo->beginTransaction();

        $stmt = $pdo->prepare('SELECT media_url FROM messages WHERE chat_id = ?');
        $stmt->execute([$chatId]);
        $mediaFiles = $stmt->fetchAll(PDO::FETCH_COLUMN);
        foreach ($mediaFiles as $url) {
            if ($url) {
                $fileName = basename($url);
                $filePath = '/var/www/api/Uploads/' . $fileName;
                if (file_exists($filePath)) {
                    unlink($filePath);
                    file_put_contents('/var/www/api/chat_log.txt', "Deleted file: $filePath" . PHP_EOL, FILE_APPEND);
                }
            }
        }

        $stmt = $pdo->prepare('DELETE FROM messages WHERE chat_id = ?');
        $stmt->execute([$chatId]);
        $stmt = $pdo->prepare('DELETE FROM chat_participants WHERE chat_id = ?');
        $stmt->execute([$chatId]);
        $stmt = $pdo->prepare('DELETE FROM chats WHERE id = ?');
        $stmt->execute([$chatId]);

        $pdo->commit();

        echo json_encode(['status' => 'success', 'message' => 'Chat deleted successfully']);
        file_put_contents('/var/www/api/chat_log.txt', "Chat deleted: chat_id=$chatId, user_id=$userId" . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        $pdo->rollBack();
        echo json_encode(['status' => 'error', 'message' => 'Failed to delete chat']);
        file_put_contents('/var/www/api/chat_log.txt', 'Delete chat error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Block user
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'block_user') {
    try {
        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Block user invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $blockedUserId = filter_var($input['blocked_user_id'] ?? 0, FILTER_VALIDATE_INT);
        $chatId = filter_var($input['chat_id'] ?? 0, FILTER_VALIDATE_INT);
        if ($blockedUserId <= 0 || $chatId <= 0) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid user ID or chat ID']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT 1 FROM chat_participants WHERE chat_id = ? AND user_id = ?');
        $stmt->execute([$chatId, $blockedUserId]);
        if (!$stmt->fetch()) {
            echo json_encode(['status' => 'error', 'message' => 'User is not a participant of this chat']);
            exit();
        }

        $stmt = $pdo->prepare('INSERT INTO blocked_users (user_id, blocked_user_id, chat_id) VALUES (?, ?, ?)');
        $stmt->execute([$userId, $blockedUserId, $chatId]);

        echo json_encode(['status' => 'success', 'message' => 'User blocked successfully']);
        file_put_contents('/var/www/api/chat_log.txt', "User blocked: user_id=$userId, blocked_user_id=$blockedUserId, chat_id=$chatId" . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to block user']);
        file_put_contents('/var/www/api/chat_log.txt', 'Block user error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Unblock user
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'unblock_user') {
    try {
        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Unblock user invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $blockedUserId = filter_var($input['blocked_user_id'] ?? 0, FILTER_VALIDATE_INT);
        $chatId = filter_var($input['chat_id'] ?? 0, FILTER_VALIDATE_INT);
        if ($blockedUserId <= 0 || $chatId <= 0) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid user ID or chat ID']);
            exit();
        }

        $stmt = $pdo->prepare('DELETE FROM blocked_users WHERE user_id = ? AND blocked_user_id = ? AND chat_id = ?');
        $stmt->execute([$userId, $blockedUserId, $chatId]);

        echo json_encode(['status' => 'success', 'message' => 'User unblocked successfully']);
        file_put_contents('/var/www/api/chat_log.txt', "Unblocked user: user_id=$userId, blocked_user_id=$blockedUserId, chat_id=$chatId" . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to unblock user']);
        file_put_contents('/var/www/api/chat_log.txt', 'Unblock user error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Check block status
if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'check_block') {
    try {
        $chatId = filter_var($_GET['chat_id'] ?? 0, FILTER_VALIDATE_INT);
        if ($chatId <= 0) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid chat ID']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT is_group FROM chats WHERE id = ?');
        $stmt->execute([$chatId]);
        $chat = $stmt->fetch(PDO::FETCH_ASSOC);
        if (!$chat) {
            echo json_encode(['status' => 'error', 'message' => 'Chat does not exist']);
            exit();
        }

        if ($chat['is_group']) {
            echo json_encode(['status' => 'success', 'is_blocked' => false]);
            exit();
        }

        $stmt = $pdo->prepare(
            'SELECT id FROM blocked_users 
             WHERE chat_id = ? 
             AND (user_id = ? OR blocked_user_id = ?)'
        );
        $stmt->execute([$chatId, $userId, $userId]);
        $block = $stmt->fetch(PDO::FETCH_ASSOC);

        echo json_encode(['status' => 'success', 'is_blocked' => !!$block]);
        file_put_contents('/var/www/api/chat_log.txt', "Checked block status: chat_id=$chatId, user_id=$userId, is_blocked=" . ($block ? 'true' : 'false') . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to check block status']);
        file_put_contents('/var/www/api/chat_log.txt', 'Check block error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Upload media
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'upload_media') {
    try {
        if (!checkRateLimit($pdo, $userId, 'upload_media')) {
            http_response_code(429);
            echo json_encode(['status' => 'error', 'message' => 'Too many upload attempts. Try again later.']);
            file_put_contents('/var/www/api/chat_log.txt', "Rate limit exceeded for upload: user_id=$userId" . PHP_EOL, FILE_APPEND);
            exit();
        }

        if (!isset($_FILES['file'])) {
            file_put_contents('/var/www/api/chat_log.txt', 'Upload error: No file provided, user_id=' . $userId . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'No file provided']);
            exit();
        }

        $file = $_FILES['file'];
        $tmpDir = ini_get('upload_tmp_dir') ?: sys_get_temp_dir();
        $error = $file['error'];
        file_put_contents('/var/www/api/chat_log.txt', "Upload attempt: user_id=$userId, name={$file['name']}, size={$file['size']}, tmp_name={$file['tmp_name']}, error=$error, tmp_dir=$tmpDir" . PHP_EOL, FILE_APPEND);

        if ($error !== UPLOAD_ERR_OK) {
            $errorMessages = [
                UPLOAD_ERR_INI_SIZE => 'File exceeds upload_max_filesize (' . ini_get('upload_max_filesize') . ')',
                UPLOAD_ERR_FORM_SIZE => 'File exceeds form size limit',
                UPLOAD_ERR_PARTIAL => 'File only partially uploaded',
                UPLOAD_ERR_NO_FILE => 'No file uploaded',
                UPLOAD_ERR_NO_TMP_DIR => "Missing temporary directory: $tmpDir",
                UPLOAD_ERR_CANT_WRITE => "Failed to write to disk: $tmpDir",
                UPLOAD_ERR_EXTENSION => 'PHP extension stopped upload'
            ];
            $message = $errorMessages[$error] ?? 'Unknown upload error';
            file_put_contents('/var/www/api/chat_log.txt', "Upload failed: user_id=$userId, error=$message" . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => $message]);
            exit();
        }

        if (!file_exists($file['tmp_name']) || !is_readable($file['tmp_name'])) {
            file_put_contents('/var/www/api/chat_log.txt', "Upload failed: Temporary file {$file['tmp_name']} does not exist or is not readable, user_id=$userId" . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Temporary file not found or not readable']);
            exit();
        }

        $allowedTypes = [
            'image/jpeg' => 'jpg',
            'image/png' => 'png',
            'image/gif' => 'gif',
            'video/mp4' => 'mp4',
            'video/quicktime' => 'mov',
            'audio/mp4' => 'm4a',
            'audio/mpeg' => 'mp3',
            'audio/wav' => 'wav',
            'application/pdf' => 'pdf'
        ];
        $maxSize = 100 * 1024 * 1024; // 100MB

        $finfo = finfo_open(FILEINFO_MIME_TYPE);
        $mimeType = finfo_file($finfo, $file['tmp_name']);
        finfo_close($finfo);

        if (!array_key_exists($mimeType, $allowedTypes)) {
            file_put_contents('/var/www/api/chat_log.txt', "Upload failed: Invalid MIME type: $mimeType, user_id=$userId" . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid file type. Allowed types: ' . implode(', ', array_keys($allowedTypes))]);
            exit();
        }

        if ($file['size'] > $maxSize) {
            file_put_contents('/var/www/api/chat_log.txt', "Upload failed: File size {$file['size']} exceeds $maxSize bytes, user_id=$userId" . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'File size exceeds 100MB']);
            exit();
        }

        $extension = $allowedTypes[$mimeType];
        $fileName = uniqid('media_') . '_' . time() . '.' . $extension;
        $uploadDir = '/var/www/api/Uploads/';
        $uploadPath = $uploadDir . $fileName;

        if (!is_dir($uploadDir)) {
            if (!mkdir($uploadDir, 0755, true)) {
                file_put_contents('/var/www/api/chat_log.txt', "Upload failed: Could not create directory $uploadDir, user_id=$userId" . PHP_EOL, FILE_APPEND);
                echo json_encode(['status' => 'error', 'message' => 'Failed to create upload directory']);
                exit();
            }
            if (!chown($uploadDir, 'www-data') || !chgrp($uploadDir, 'www-data') || !chmod($uploadDir, 0755)) {
                file_put_contents('/var/www/api/chat_log.txt', "Upload failed: Could not set permissions for $uploadDir, user_id=$userId" . PHP_EOL, FILE_APPEND);
                echo json_encode(['status' => 'error', 'message' => 'Failed to set upload directory permissions']);
                exit();
            }
        }

        if (!is_writable($uploadDir)) {
            file_put_contents('/var/www/api/chat_log.txt', "Upload failed: Directory $uploadDir is not writable, user_id=$userId" . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Upload directory not writable']);
            exit();
        }

        if (!move_uploaded_file($file['tmp_name'], $uploadPath)) {
            $error = error_get_last();
            file_put_contents('/var/www/api/chat_log.txt', "Upload failed: Could not move file to $uploadPath, error: " . ($error['message'] ?? 'Unknown error') . ", user_id=$userId" . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Failed to move uploaded file: ' . ($error['message'] ?? 'Unknown error')]);
            exit();
        }

        if (!chown($uploadPath, 'www-data') || !chgrp($uploadPath, 'www-data') || !chmod($uploadPath, 0644)) {
            file_put_contents('/var/www/api/chat_log.txt', "Warning: Could not set permissions for $uploadPath, user_id=$userId" . PHP_EOL, FILE_APPEND);
        }

        $url = "http://147.93.177.26/Uploads/$fileName";
        $fileType = in_array($mimeType, ['video/mp4', 'video/quicktime']) ? 'video' : (in_array($mimeType, ['image/jpeg', 'image/png', 'image/gif']) ? 'image' : (in_array($mimeType, ['audio/mp4', 'audio/mpeg', 'audio/wav']) ? 'audio' : 'document'));
        echo json_encode(['status' => 'success', 'url' => $url, 'file_type' => $fileType]);
        file_put_contents('/var/www/api/chat_log.txt', "File uploaded: $uploadPath, user_id=$userId, url=$url, type=$fileType, size={$file['size']} bytes, mime_type=$mimeType" . PHP_EOL, FILE_APPEND);
    } catch (Exception $e) {
        file_put_contents('/var/www/api/chat_log.txt', 'Upload media error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL . 'user_id=' . $userId . PHP_EOL, FILE_APPEND);
        echo json_encode(['status' => 'error', 'message' => 'Failed to upload media: ' . $e->getMessage()]);
    }
    exit();
}

// Set typing status
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'set_typing') {
    try {
        if (!checkRateLimit($pdo, $userId, 'set_typing')) {
            echo json_encode(['status' => 'error', 'message' => 'Too many typing status updates. Try again later.']);
            exit();
        }

        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Set typing invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $chatId = filter_var($input['chat_id'] ?? 0, FILTER_VALIDATE_INT);
        $isTyping = filter_var($input['is_typing'] ?? false, FILTER_VALIDATE_BOOLEAN);
        if ($chatId <= 0) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid chat ID']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT 1 FROM chat_participants WHERE chat_id = ? AND user_id = ?');
        $stmt->execute([$chatId, $userId]);
        if (!$stmt->fetch()) {
            echo json_encode(['status' => 'error', 'message' => 'You are not a participant of this chat']);
            exit();
        }

        $stmt = $pdo->prepare(
            'INSERT INTO typing_status (chat_id, user_id, is_typing, updated_at)
             VALUES (?, ?, ?, NOW())
             ON DUPLICATE KEY UPDATE is_typing = ?, updated_at = NOW()'
        );
        $stmt->execute([$chatId, $userId, $isTyping ? 1 : 0, $isTyping ? 1 : 0]);

        echo json_encode(['status' => 'success', 'message' => 'Typing status updated']);
        file_put_contents('/var/www/api/chat_log.txt', "Typing status updated: chat_id=$chatId, user_id=$userId, is_typing=$isTyping" . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to update typing status']);
        file_put_contents('/var/www/api/chat_log.txt', 'Set typing error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Get typing status
if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'get_typing') {
    try {
        $chatId = filter_var($_GET['chat_id'] ?? 0, FILTER_VALIDATE_INT);
        if ($chatId <= 0) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid chat ID']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT 1 FROM chat_participants WHERE chat_id = ? AND user_id = ?');
        $stmt->execute([$chatId, $userId]);
        if (!$stmt->fetch()) {
            echo json_encode(['status' => 'error', 'message' => 'You are not a participant of this chat']);
            exit();
        }

        $stmt = $pdo->prepare(
            'SELECT u.id, u.username, t.is_typing
             FROM typing_status t
             JOIN users u ON t.user_id = u.id
             WHERE t.chat_id = ?
             AND t.user_id != ?
             AND t.updated_at > NOW() - INTERVAL 10 SECOND'
        );
        $stmt->execute([$chatId, $userId]);
        $typingUsers = $stmt->fetchAll(PDO::FETCH_ASSOC);

        echo json_encode(['status' => 'success', 'typing_users' => $typingUsers]);
        file_put_contents('/var/www/api/chat_log.txt', "Fetched typing status: chat_id=$chatId, user_id=$userId, count=" . count($typingUsers) . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to fetch typing status']);
        file_put_contents('/var/www/api/chat_log.txt', 'Get typing error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Set nickname
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'set_nickname') {
    try {
        if (!checkRateLimit($pdo, $userId, 'set_nickname')) {
            echo json_encode(['status' => 'error', 'message' => 'Too many nickname updates. Try again later.']);
            exit();
        }

        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Set nickname invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $targetId = filter_var($input['target_id'] ?? 0, FILTER_VALIDATE_INT);
        $isGroup = filter_var($input['is_group'] ?? false, FILTER_VALIDATE_BOOLEAN);
        $nickname = trim($input['nickname'] ?? '');

        if ($targetId <= 0) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid target ID']);
            exit();
        }
        if (empty($nickname) || strlen($nickname) < 3) {
            echo json_encode(['status' => 'error', 'message' => 'Nickname must be at least 3 characters']);
            exit();
        }

        if ($isGroup) {
            $stmt = $pdo->prepare('SELECT 1 FROM chats WHERE id = ? AND is_group = 1');
            $stmt->execute([$targetId]);
        } else {
            $stmt = $pdo->prepare('SELECT 1 FROM users WHERE id = ?');
            $stmt->execute([$targetId]);
        }
        if (!$stmt->fetch()) {
            echo json_encode(['status' => 'error', 'message' => $isGroup ? 'Group not found' : 'User not found']);
            exit();
        }

        $stmt = $pdo->prepare(
            'INSERT INTO nicknames (user_id, target_id, is_group, nickname)
             VALUES (?, ?, ?, ?)
             ON DUPLICATE KEY UPDATE nickname = ?'
        );
        $stmt->execute([$userId, $targetId, $isGroup ? 1 : 0, $nickname, $nickname]);

        echo json_encode(['status' => 'success', 'message' => 'Nickname updated successfully']);
        file_put_contents('/var/www/api/chat_log.txt', "Nickname updated: user_id=$userId, target_id=$targetId, is_group=$isGroup, nickname=$nickname" . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to update nickname']);
        file_put_contents('/var/www/api/chat_log.txt', 'Update nickname error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Get nicknames
if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'get_nicknames') {
    try {
        $stmt = $pdo->prepare(
            'SELECT target_id, is_group, nickname 
             FROM nicknames 
             WHERE user_id = ?'
        );
        $stmt->execute([$userId]);
        $nicknames = $stmt->fetchAll(PDO::FETCH_ASSOC);

        echo json_encode(['status' => 'success', 'nicknames' => $nicknames]);
        file_put_contents('/var/www/api/chat_log.txt', "Fetched nicknames for user_id=$userId, count=" . count($nicknames) . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        echo json_encode(['status' => 'error', 'message' => 'Failed to fetch nicknames']);
        file_put_contents('/var/www/api/chat_log.txt', 'Fetch nicknames error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Forward message
if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'forward_message') {
    try {
        if (!checkRateLimit($pdo, $userId, 'forward_message')) {
            echo json_encode(['status' => 'error', 'message' => 'Too many forwarded messages']);
            exit();
        }

        $input = json_decode(file_get_contents('php://input'), true);
        if (json_last_error() !== JSON_ERROR_NONE) {
            file_put_contents('/var/www/api/chat_log.txt', 'Forwarded message invalid JSON: ' . json_last_error_msg() . PHP_EOL, FILE_APPEND);
            echo json_encode(['status' => 'error', 'message' => 'Invalid JSON']);
            exit();
        }

        $messageId = filter_var($input['message_id'] ?? 0, FILTER_VALIDATE_INT);
        $targetChatId = filter_var($input['target_chat_id'] ?? 0, FILTER_VALIDATE_INT);
        if ($messageId <= 0 || $targetChatId <= 0) {
            echo json_encode(['status' => 'error', 'message' => 'Invalid message ID or target chat ID']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT chat_id, type, content, media_url FROM messages WHERE id = ?');
        $stmt->execute([$messageId]);
        $message = $stmt->fetch(PDO::FETCH_ASSOC);
        if (!$message) {
            echo json_encode(['status' => 'error', 'message' => 'Message not found']);
            exit();
        }

        $stmt = $pdo->prepare('SELECT 1 FROM chat_participants WHERE chat_id = ? AND user_id = ?');
        $stmt->execute([$targetChatId, $userId]);
        if (!$stmt->fetch()) {
            echo json_encode(['status' => 'error', 'message' => 'You are not a participant of the target chat']);
            exit();
        }

        $stmt = $pdo->prepare(
            'SELECT id FROM blocked_users 
             WHERE chat_id = ? 
             AND ((user_id = ? AND blocked_user_id IN (SELECT user_id FROM chat_participants WHERE chat_id = ?)) OR 
                  (blocked_user_id = ? AND user_id IN (SELECT user_id FROM chat_participants WHERE chat_id = ?)))'
        );
        $stmt->execute([$targetChatId, $userId, $targetChatId, $userId, $targetChatId]);
        if ($stmt->fetch()) {
            echo json_encode(['status' => 'error', 'message' => 'Cannot forward message due to blocked user']);
            exit();
        }

        $pdo->beginTransaction();
        $stmt = $pdo->prepare(
            'INSERT INTO messages (chat_id, sender_id, type, content, media_url, created_at)
             VALUES (?, ?, ?, ?, ?, NOW())'
        );
        $stmt->execute([$targetChatId, $userId, $message['type'], $message['content'], $message['media_url']]);
        $newMessageId = $pdo->lastInsertId();
        $pdo->commit();

        echo json_encode(['status' => 'success', 'message_id' => $newMessageId, 'message' => 'Message forwarded successfully']);
        file_put_contents('/var/www/api/chat_log.txt', "Forwarded message: message_id=$newMessageId, chat_id=$targetChatId, from_message_id=$messageId, user_id=$userId" . PHP_EOL, FILE_APPEND);
    } catch (PDOException $e) {
        $pdo->rollBack();
        echo json_encode(['status' => 'error', 'message' => 'Failed to forward message']);
        file_put_contents('/var/www/api/chat_log.txt', 'Forward message error: ' . $e->getMessage() . PHP_EOL . 'Trace: ' . $e->getTraceAsString() . PHP_EOL, FILE_APPEND);
    }
    exit();
}

// Default response for invalid actions
http_response_code(400);
echo json_encode(['status' => 'error', 'message' => 'Invalid action']);
file_put_contents('/var/www/api/chat_log.txt', "Invalid action requested: $action, user_id=$userId" . PHP_EOL, FILE_APPEND);
exit();
?>