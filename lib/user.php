<?php
ob_start();
ini_set('display_errors', 0);
ini_set('display_startup_errors', 0);
ini_set('log_errors', 1);
ini_set('error_log', '/var/log/php_errors.log');
error_reporting(E_ALL);

header('Content-Type: application/json; charset=UTF-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, POST, DELETE');
header('Access-Control-Allow-Headers: Content-Type, Session-Id, Session-ID');

$host = 'localhost';
$dbname = 'chat_appp';
$username = 'root';
$password = '1234Qwertyumer';

try {
    $pdo = new PDO("mysql:host=$host;dbname=$dbname", $username, $password);
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->setAttribute(PDO::ATTR_DEFAULT_FETCH_MODE, PDO::FETCH_ASSOC);
    file_put_contents('/var/www/api/user_log.txt', "Database connected: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
} catch (PDOException $e) {
    $response = ['status' => 'error', 'message' => 'Database connection failed: ' . $e->getMessage()];
    file_put_contents('/var/www/api/user_log.txt', "Error: " . json_encode($response) . "\n---\n", FILE_APPEND);
    echo json_encode($response);
    ob_end_flush();
    exit;
}

function sendResponse($data, $status = 200) {
    http_response_code($status);
    try {
        echo json_encode($data, JSON_THROW_ON_ERROR);
        file_put_contents('/var/www/api/user_log.txt', "Response: " . json_encode($data) . " at " . date('Y-m-d H:i:s') . "\n---\n", FILE_APPEND);
    } catch (JsonException $e) {
        $response = ['status' => 'error', 'message' => 'JSON encoding failed: ' . $e->getMessage()];
        file_put_contents('/var/www/api/user_log.txt', "Error: " . json_encode($response) . " at " . date('Y-m-d H:i:s') . "\n---\n", FILE_APPEND);
        echo json_encode($response);
    }
    ob_end_flush();
    exit;
}

function validateSession($pdo, $sessionId) {
    if (empty($sessionId)) {
        file_put_contents('/var/www/api/user_log.txt', "Validating session ID: empty, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'No session ID provided'], 401);
    }

    try {
        $stmt = $pdo->prepare('SELECT user_id, expires_at FROM sessions WHERE session_id = ?');
        $stmt->execute([$sessionId]);
        $session = $stmt->fetch();

        if (!$session) {
            file_put_contents('/var/www/api/user_log.txt', "Invalid session ID: $sessionId, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Invalid session'], 401);
        }

        if (strtotime($session['expires_at']) < time()) {
            file_put_contents('/var/www/api/user_log.txt', "Session expired: $sessionId, expires_at: {$session['expires_at']}, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Session expired'], 401);
        }

        $newExpiresAt = date('Y-m-d H:i:s', strtotime('+1 hour'));
        $stmt = $pdo->prepare('UPDATE sessions SET expires_at = ? WHERE session_id = ?');
        $stmt->execute([$newExpiresAt, $sessionId]);

        file_put_contents('/var/www/api/user_log.txt', "Session validated: user_id={$session['user_id']}, expires_at=$newExpiresAt, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
        return $session['user_id'];
    } catch (PDOException $e) {
        file_put_contents('/var/www/api/user_log.txt', "Session validation error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Session validation failed: ' . $e->getMessage()], 500);
    }
}

function checkRateLimit($pdo, $userId, $actionType) {
    try {
        $stmt = $pdo->prepare('SELECT COUNT(*) FROM rate_limits WHERE user_id = ? AND action_type = ? AND action_time > NOW() - INTERVAL 1 MINUTE');
        $stmt->execute([$userId, $actionType]);
        $attempts = $stmt->fetchColumn();

        $limits = [
            'get_users' => 20,
            'search_users' => 30,
            'verify_session' => 50,
            'send_message' => 20,
            'create_chat' => 5,
            'upload_media' => 10,
            'register' => 5,
            'login' => 10,
            'update_profile' => 5,
            'set_typing' => 20,
            'set_nickname' => 10,
            'forward_message' => 10,
            'toggle_privacy' => 5,
            'get_privacy_settings' => 10,
            'update_profile_photo' => 5,
            'update_status_media' => 5,
            'update_cover_photo' => 5,
            'set_verification_status' => 5,
            'update_visibility' => 10, // Added for visibility updates
        ];
        $limit = $limits[$actionType] ?? 5;

        if ($attempts >= $limit) {
            file_put_contents('/var/www/api/user_log.txt', "Rate limit exceeded: user_id=$userId, action_type=$actionType, attempts=$attempts, limit=$limit, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Too many requests. Try again later.'], 429);
        }

        $stmt = $pdo->prepare('INSERT INTO rate_limits (user_id, action_type, action_time) VALUES (?, ?, NOW())');
        $stmt->execute([$userId, $actionType]);
        file_put_contents('/var/www/api/user_log.txt', "Rate limit recorded: user_id=$userId, action_type=$actionType, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
        return true;
    } catch (PDOException $e) {
        file_put_contents('/var/www/api/user_log.txt', "Rate limit error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        return true;
    }
}

$sessionId = null;
$headers = getallheaders();
foreach ($headers as $key => $value) {
    if (strtolower($key) === 'session-id') {
        $sessionId = $value;
        break;
    }
}
$sessionId = $sessionId ?? ($_SERVER['HTTP_SESSION_ID'] ?? '');
file_put_contents('/var/www/api/user_log.txt', "Received Session-Id: " . ($sessionId ?: 'none') . ", Method: {$_SERVER['REQUEST_METHOD']}, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

$input = [];
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $rawInput = file_get_contents('php://input');
    if (!empty($rawInput)) {
        try {
            $input = json_decode($rawInput, true);
            if (json_last_error() !== JSON_ERROR_NONE) {
                file_put_contents('/var/www/api/user_log.txt', "Invalid JSON input: " . json_last_error_msg() . ", Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
                sendResponse(['status' => 'error', 'message' => 'Invalid JSON'], 400);
            }
            file_put_contents('/var/www/api/user_log.txt', "POST input: " . json_encode($input) . ", Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
        } catch (Exception $e) {
            file_put_contents('/var/www/api/user_log.txt', "JSON decode error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Invalid JSON'], 400);
        }
    }
}

$action = $_GET['action'] ?? ($input['action'] ?? null);
file_put_contents('/var/www/api/user_log.txt', "Action: " . ($action ?: 'none') . ", Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
if ($action === null) {
    sendResponse(['status' => 'error', 'message' => 'Action parameter is required'], 400);
}

if ($action !== 'serve_media' && $action !== 'register' && $action !== 'login') {
    $userId = validateSession($pdo, $sessionId);
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'register') {
    try {
        if (!checkRateLimit($pdo, 0, 'register')) {
            exit;
        }

        $username = trim($input['username'] ?? '');
        $email = trim($input['email'] ?? '');
        $password = trim($input['password'] ?? '');

        if (strlen($username) < 3) {
            sendResponse(['status' => 'error', 'message' => 'Username must be at least 3 characters'], 400);
        }
        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid email address'], 400);
        }
        if (strlen($password) < 8) {
            sendResponse(['status' => 'error', 'message' => 'Password must be at least 8 characters'], 400);
        }

        $hashedPassword = password_hash($password, PASSWORD_BCRYPT);
        $stmt = $pdo->prepare('INSERT INTO users (username, email, password, created_at, is_verified) VALUES (?, ?, ?, NOW(), 0)');
        $stmt->execute([$username, $email, $hashedPassword]);
        $userId = $pdo->lastInsertId();

        sendResponse(['status' => 'success', 'user_id' => $userId, 'message' => 'User registered successfully']);
    } catch (PDOException $e) {
        file_put_contents('/var/www/api/user_log.txt', "Register error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Failed to register user: ' . $e->getMessage()], 500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'login') {
    try {
        if (!checkRateLimit($pdo, 0, 'login')) {
            exit;
        }

        $email = trim($input['email'] ?? '');
        $password = trim($input['password'] ?? '');

        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid email address'], 400);
        }
        if (empty($password)) {
            sendResponse(['status' => 'error', 'message' => 'Password is required'], 400);
        }

        $stmt = $pdo->prepare('SELECT id, username, password, is_verified FROM users WHERE email = ?');
        $stmt->execute([$email]);
        $user = $stmt->fetch();

        if (!$user || !password_verify($password, $user['password'])) {
            sendResponse(['status' => 'error', 'message' => 'Invalid email or password'], 400);
        }

        $stmt = $pdo->prepare('DELETE FROM sessions WHERE user_id = ?');
        $stmt->execute([$user['id']]);

        $sessionId = bin2hex(random_bytes(32));
        $expiresAt = date('Y-m-d H:i:s', strtotime('+1 hour'));
        $stmt = $pdo->prepare('INSERT INTO sessions (user_id, session_id, expires_at) VALUES (?, ?, ?)');
        $stmt->execute([$user['id'], $sessionId, $expiresAt]);

        sendResponse([
            'status' => 'success',
            'session_id' => $sessionId,
            'user_id' => $user['id'],
            'username' => $user['username'],
            'is_verified' => (bool)$user['is_verified'],
            'message' => 'Login successful'
        ]);
    } catch (Exception $e) {
        file_put_contents('/var/www/api/user_log.txt', "Login error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Failed to login: ' . $e->getMessage()], 500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'verify_session') {
    try {
        $userId = validateSession($pdo, $sessionId);
        $stmt = $pdo->prepare('SELECT username, email, is_verified FROM users WHERE id = ?');
        $stmt->execute([$userId]);
        $user = $stmt->fetch();

        if ($user) {
            sendResponse([
                'status' => 'success',
                'user_id' => $userId,
                'username' => $user['username'],
                'email' => $user['email'],
                'is_verified' => (bool)$user['is_verified']
            ]);
        } else {
            sendResponse(['status' => 'error', 'message' => 'User not found'], 404);
        }
    } catch (Exception $e) {
        file_put_contents('/var/www/api/user_log.txt', "Verify session error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Session verification failed: ' . $e->getMessage()], 500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'get_users') {
    try {
        if (!checkRateLimit($pdo, $userId, 'get_users')) {
            exit;
        }

        $stmt = $pdo->prepare('SELECT id, email, username, profile_photo_url, status_photo_url, status_video_url, cover_photo_url, is_verified FROM users WHERE id != ? AND (status_visibility = "Everyone" OR status_visibility = "My contacts")');
        $stmt->execute([$userId]);
        $users = $stmt->fetchAll();
        sendResponse(['status' => 'success', 'users' => $users]);
    } catch (Exception $e) {
        file_put_contents('/var/www/api/user_log.txt', "Get users error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Failed to fetch users: ' . $e->getMessage()], 500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'search_users') {
    try {
        if (!checkRateLimit($pdo, $userId, 'search_users')) {
            exit;
        }

        $query = trim($_GET['query'] ?? '');
        file_put_contents('/var/www/api/user_log.txt', "Search query: $query, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

        if (empty($query) || strlen($query) > 100 || !preg_match('/^[a-zA-Z0-9@._-]+$/', $query)) {
            sendResponse(['status' => 'error', 'message' => 'Search query required, must be under 100 characters, and contain only alphanumeric, @, ., _, or -'], 400);
        }

        $stmt = $pdo->prepare('SELECT id, email, username, profile_photo_url, status_photo_url, status_video_url, cover_photo_url, is_verified FROM users WHERE (username LIKE ? OR email LIKE ?) AND id != ?');
        $stmt->execute(['%' . $query . '%', '%' . $query . '%', $userId]);
        $users = $stmt->fetchAll();
        sendResponse(['status' => 'success', 'users' => $users]);
    } catch (Exception $e) {
        file_put_contents('/var/www/api/user_log.txt', "Search users error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Search failed: ' . $e->getMessage()], 500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'GET' && $action === 'get_privacy_settings') {
    try {
        if (!checkRateLimit($pdo, $userId, 'get_privacy_settings')) {
            exit;
        }

        $stmt = $pdo->prepare('SELECT is_private, profile_photo_url, status_photo_url, status_video_url, cover_photo_url, profile_visibility, status_visibility, cover_visibility, last_seen_visibility, about_visibility, groups_visibility, is_verified FROM users WHERE id = ?');
        $stmt->execute([$userId]);
        $user = $stmt->fetch();

        if ($user) {
            $response = [
                'status' => 'success',
                'is_private' => (bool)($user['is_private'] ?? false),
                'profile_photo_url' => $user['profile_photo_url'] ?? null,
                'status_photo_url' => $user['status_photo_url'] ?? null,
                'status_video_url' => $user['status_video_url'] ?? null,
                'cover_photo_url' => $user['cover_photo_url'] ?? null,
                'profile_visibility' => $user['profile_visibility'] ?? 'Everyone',
                'status_visibility' => $user['status_visibility'] ?? 'My contacts',
                'cover_visibility' => $user['cover_visibility'] ?? 'Everyone',
                'last_seen_visibility' => $user['last_seen_visibility'] ?? 'Nobody',
                'about_visibility' => $user['about_visibility'] ?? 'My contacts',
                'groups_visibility' => $user['groups_visibility'] ?? 'My contacts',
                'is_verified' => (bool)($user['is_verified'] ?? false),
            ];
            file_put_contents('/var/www/api/user_log.txt', "Privacy settings fetched for user_id=$userId: " . json_encode($response) . ", Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse($response);
        } else {
            file_put_contents('/var/www/api/user_log.txt', "User not found for user_id=$userId, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'User not found'], 404);
        }
    } catch (PDOException $e) {
        $errorLog = "get_privacy_settings error for user_id=$userId: " . $e->getMessage() . "\nTrace: " . $e->getTraceAsString() . "\n";
        file_put_contents('/var/www/api/user_log.txt', $errorLog, FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Failed to fetch privacy settings: ' . $e->getMessage()], 500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'toggle_privacy') {
    try {
        if (!checkRateLimit($pdo, $userId, 'toggle_privacy')) {
            exit;
        }

        $isPrivate = filter_var($input['is_private'] ?? '0', FILTER_VALIDATE_BOOLEAN);
        $stmt = $pdo->prepare('UPDATE users SET is_private = ? WHERE id = ?');
        $stmt->execute([$isPrivate ? 1 : 0, $userId]);

        sendResponse(['status' => 'success', 'message' => 'Privacy updated successfully']);
    } catch (PDOException $e) {
        file_put_contents('/var/www/api/user_log.txt', "Toggle privacy error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Failed to update privacy: ' . $e->getMessage()], 500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'upload_media') {
    try {
        if (!checkRateLimit($pdo, $userId, 'upload_media')) {
            exit;
        }

        if (!isset($_FILES['file'])) {
            file_put_contents('/var/www/api/user_log.txt', "Upload error: No file provided, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'No file provided'], 400);
        }

        $file = $_FILES['file'];
        $tmpDir = ini_get('upload_tmp_dir') ?: sys_get_temp_dir();
        $error = $file['error'];
        file_put_contents('/var/www/api/user_log.txt', "Upload attempt: name={$file['name']}, size={$file['size']}, tmp_name={$file['tmp_name']}, error=$error, tmp_dir=$tmpDir, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

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
            file_put_contents('/var/www/api/user_log.txt', "Upload failed: $message, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => $message], 400);
        }

        if (!file_exists($file['tmp_name'])) {
            file_put_contents('/var/www/api/user_log.txt', "Upload failed: Temporary file {$file['tmp_name']} does not exist, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Temporary file not found'], 400);
        }

        $allowedTypes = ['image/jpeg', 'image/png', 'image/gif', 'video/mp4', 'video/quicktime'];
        $maxSize = 100 * 1024 * 1024; // 100MB

        $finfo = finfo_open(FILEINFO_MIME_TYPE);
        $mimeType = finfo_file($finfo, $file['tmp_name']);
        finfo_close($finfo);

        if (!in_array($mimeType, $allowedTypes)) {
            file_put_contents('/var/www/api/user_log.txt', "Upload failed: Invalid MIME type: $mimeType, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Invalid file type'], 400);
        }

        if ($file['size'] > $maxSize) {
            file_put_contents('/var/www/api/user_log.txt', "Upload failed: File size {$file['size']} exceeds $maxSize bytes, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'File size exceeds 100MB'], 400);
        }

        $extension = strtolower(pathinfo($file['name'], PATHINFO_EXTENSION));
        $fileName = uniqid() . '_' . time() . '.' . $extension;
        $uploadDir = '/var/www/api/Uploads/';
        $uploadPath = $uploadDir . $fileName;

        if (!is_dir($uploadDir)) {
            if (!mkdir($uploadDir, 0755, true)) {
                file_put_contents('/var/www/api/user_log.txt', "Upload failed: Could not create directory $uploadDir, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
                sendResponse(['status' => 'error', 'message' => 'Failed to create upload directory'], 500);
            }
            if (!chown($uploadDir, 'www-data') || !chmod($uploadDir, 0755)) {
                file_put_contents('/var/www/api/user_log.txt', "Upload failed: Could not set permissions for $uploadDir, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
                sendResponse(['status' => 'error', 'message' => 'Failed to set upload directory permissions'], 500);
            }
        }

        if (!is_writable($uploadDir)) {
            file_put_contents('/var/www/api/user_log.txt', "Upload failed: Directory $uploadDir is not writable, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Upload directory not writable'], 500);
        }

        if (!move_uploaded_file($file['tmp_name'], $uploadPath)) {
            $error = error_get_last();
            file_put_contents('/var/www/api/user_log.txt', "Upload failed: Could not move file to $uploadPath, error: " . ($error['message'] ?? 'Unknown error') . ", Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Failed to move uploaded file: ' . ($error['message'] ?? 'Unknown error')], 500);
        }

        if (!chown($uploadPath, 'www-data') || !chmod($uploadPath, 0644)) {
            file_put_contents('/var/www/api/user_log.txt', "Warning: Could not set permissions for $uploadPath, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
        }

        $url = "http://147.93.177.26/Uploads/$fileName";
        sendResponse(['status' => 'success', 'url' => $url]);
        file_put_contents('/var/www/api/user_log.txt', "File uploaded: $uploadPath, user_id=$userId, url=$url, size={$file['size']} bytes, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
    } catch (Exception $e) {
        file_put_contents('/var/www/api/user_log.txt', "Upload media error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Failed to upload media: ' . $e->getMessage()], 500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'update_profile_photo') {
    try {
        if (!checkRateLimit($pdo, $userId, 'update_profile_photo')) {
            exit;
        }

        $photoUrl = trim($input['media_url'] ?? '');
        if (empty($photoUrl) || !filter_var($photoUrl, FILTER_VALIDATE_URL)) {
            file_put_contents('/var/www/api/user_log.txt', "Invalid profile photo URL: $photoUrl, user_id=$userId, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Invalid photo URL'], 400);
        }

        $stmt = $pdo->prepare('UPDATE users SET profile_photo_url = ? WHERE id = ?');
        $stmt->execute([$photoUrl, $userId]);
        file_put_contents('/var/www/api/user_log.txt', "Profile photo updated: user_id=$userId, url=$photoUrl, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

        sendResponse(['status' => 'success', 'message' => 'Profile photo updated successfully']);
    } catch (PDOException $e) {
        file_put_contents('/var/www/api/user_log.txt', "Update profile photo error: " . $e->getMessage() . ", user_id=$userId, Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Failed to update profile photo: ' . $e->getMessage()], 500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'update_status_media') {
    try {
        if (!checkRateLimit($pdo, $userId, 'update_status_media')) {
            exit;
        }

        $mediaUrl = trim($input['media_url'] ?? '');
        $mediaType = trim($input['media_type'] ?? 'photo');
        if (empty($mediaUrl) || !filter_var($mediaUrl, FILTER_VALIDATE_URL)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid media URL'], 400);
        }

        if ($mediaType === 'photo') {
            $stmt = $pdo->prepare('UPDATE users SET status_photo_url = ?, status_video_url = NULL WHERE id = ?');
            $stmt->execute([$mediaUrl, $userId]);
            sendResponse(['status' => 'success', 'message' => 'Status photo updated successfully']);
        } else if ($mediaType === 'video') {
            $stmt = $pdo->prepare('UPDATE users SET status_video_url = ?, status_photo_url = NULL WHERE id = ?');
            $stmt->execute([$mediaUrl, $userId]);
            sendResponse(['status' => 'success', 'message' => 'Status video updated successfully']);
        } else {
            sendResponse(['status' => 'error', 'message' => 'Invalid media type'], 400);
        }
    } catch (PDOException $e) {
        file_put_contents('/var/www/api/user_log.txt', "Update status media error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Failed to update status media: ' . $e->getMessage()], 500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'update_cover_photo') {
    try {
        if (!checkRateLimit($pdo, $userId, 'update_cover_photo')) {
            exit;
        }

        $photoUrl = trim($input['media_url'] ?? '');
        if (empty($photoUrl) || !filter_var($photoUrl, FILTER_VALIDATE_URL)) {
            sendResponse(['status' => 'error', 'message' => 'Invalid photo URL'], 400);
        }

        $stmt = $pdo->prepare('UPDATE users SET cover_photo_url = ? WHERE id = ?');
        $stmt->execute([$photoUrl, $userId]);

        sendResponse(['status' => 'success', 'message' => 'Cover photo updated successfully']);
    } catch (PDOException $e) {
        file_put_contents('/var/www/api/user_log.txt', "Update cover photo error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Failed to update cover photo: ' . $e->getMessage()], 500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'set_verification_status') {
    try {
        if (!checkRateLimit($pdo, $userId, 'set_verification_status')) {
            exit;
        }

        $requestUserId = trim($input['user_id'] ?? '');
        $isVerified = filter_var($input['is_verified'] ?? false, FILTER_VALIDATE_BOOLEAN);

        if ($requestUserId != $userId) {
            file_put_contents('/var/www/api/user_log.txt', "Unauthorized: user_id=$userId attempted to verify user_id=$requestUserId, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Unauthorized'], 403);
        }

        $stmt = $pdo->prepare('UPDATE users SET is_verified = ? WHERE id = ?');
        $stmt->execute([$isVerified ? 1 : 0, $userId]);
        file_put_contents('/var/www/api/user_log.txt', "Verification status updated: user_id=$userId, is_verified=$isVerified, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

        sendResponse(['status' => 'success', 'message' => 'Verification status updated successfully']);
    } catch (PDOException $e) {
        file_put_contents('/var/www/api/user_log.txt', "Set verification status error: " . $e->getMessage() . ", Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Failed to update verification status: ' . $e->getMessage()], 500);
    }
}

if ($_SERVER['REQUEST_METHOD'] === 'POST' && $action === 'update_visibility') {
    try {
        if (!checkRateLimit($pdo, $userId, 'update_visibility')) {
            exit;
        }

        $type = trim($input['type'] ?? '');
        $value = trim($input['value'] ?? '');

        $allowedTypes = ['profile', 'status', 'cover', 'last_seen', 'about', 'groups'];
        $allowedValues = ['Everyone', 'My contacts', 'Nobody'];

        if (!in_array($type, $allowedTypes)) {
            file_put_contents('/var/www/api/user_log.txt', "Invalid visibility type: $type, user_id=$userId, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Invalid visibility type'], 400);
        }

        if (!in_array($value, $allowedValues)) {
            file_put_contents('/var/www/api/user_log.txt', "Invalid visibility value: $value, user_id=$userId, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);
            sendResponse(['status' => 'error', 'message' => 'Invalid visibility value'], 400);
        }

        $columnMap = [
            'profile' => 'profile_visibility',
            'status' => 'status_visibility',
            'cover' => 'cover_visibility',
            'last_seen' => 'last_seen_visibility',
            'about' => 'about_visibility',
            'groups' => 'groups_visibility',
        ];

        $column = $columnMap[$type];
        $stmt = $pdo->prepare("UPDATE users SET $column = ? WHERE id = ?");
        $stmt->execute([$value, $userId]);
        file_put_contents('/var/www/api/user_log.txt', "Visibility updated: user_id=$userId, type=$type, value=$value, Time: " . date('Y-m-d H:i:s') . "\n", FILE_APPEND);

        sendResponse(['status' => 'success', 'message' => 'Visibility updated successfully']);
    } catch (PDOException $e) {
        file_put_contents('/var/www/api/user_log.txt', "Update visibility error: " . $e->getMessage() . ", user_id=$userId, Time: " . date('Y-m-d H:i:s') . "\nTrace: " . $e->getTraceAsString() . "\n---\n", FILE_APPEND);
        sendResponse(['status' => 'error', 'message' => 'Failed to update visibility: ' . $e->getMessage()], 500);
    }
}

sendResponse(['status' => 'error', 'message' => 'Invalid action'], 400);
?>