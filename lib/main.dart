import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const TermuxSshBridgeApp());
}

class TermuxSshBridgeApp extends StatelessWidget {
  const TermuxSshBridgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Termux SSH Bridge',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        primaryColor: const Color(0xFF38BDF8),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF818CF8),
          surface: Color(0xFF1E293B),
        ),
        fontFamily: 'monospace',
        useMaterial3: true,
      ),
      home: const DashboardScreen(),
    );
  }
}

class LogEntry {
  final String text;
  final Color color;
  final DateTime timestamp;

  LogEntry(this.text, {this.color = Colors.white}) : timestamp = DateTime.now();
}

class SSHProfile {
  String id;
  String name;
  String host;
  String port;
  String username;

  SSHProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
      };

  factory SSHProfile.fromJson(Map<String, dynamic> json) => SSHProfile(
        id: json['id'],
        name: json['name'],
        host: json['host'],
        port: json['port'],
        username: json['username'],
      );
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Connection Controllers
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8022');
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();

  // Command & Terminal Controllers
  final _commandController = TextEditingController();
  final _scrollController = ScrollController();

  final _secureStorage = const FlutterSecureStorage();

  SSHClient? _client;
  bool _isConnected = false;
  bool _isConnecting = false;
  double _fontSize = 13.0;

  final List<LogEntry> _logs = [];
  List<SSHProfile> _profiles = [];
  String? _activeProfileId;

  // Custom Quick Command Macros
  List<Map<String, String>> _quickCommands = [
    {'name': 'Whoami & Env', 'cmd': 'whoami && uname -a && pwd'},
    {
      'name': 'PRoot Info',
      'cmd': 'proot --version || echo "PRoot active via standard termux"'
    },
    {'name': 'Disk Usage', 'cmd': 'df -h'},
    {
      'name': 'Tailscale Status',
      'cmd': 'tailscale status || echo "Tailscale service running on host"'
    },
    {
      'name': 'Coding Agent (Git Status)',
      'cmd': 'git status || echo "Not a git repo"'
    },
    {'name': 'Python Agent Test', 'cmd': 'python3 --version && pip list'},
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadSavedData();
  }

  Future<void> _loadSavedData() async {
    final prefs = await SharedPreferences.getInstance();

    final profilesJson = prefs.getStringList('ssh_profiles');
    if (profilesJson != null && profilesJson.isNotEmpty) {
      setState(() {
        _profiles = profilesJson
            .map((p) => SSHProfile.fromJson(jsonDecode(p)))
            .toList();
      });
    } else {
      _profiles = [
        SSHProfile(
            id: 'default',
            name: 'Default Tailscale Termux',
            host: '',
            port: '8022',
            username: ''),
      ];
    }
    _activeProfileId =
        prefs.getString('active_profile_id') ?? _profiles.first.id;
    _loadProfileToControllers(_activeProfileId!);

    final customCmdsJson = prefs.getStringList('custom_quick_cmds');
    if (customCmdsJson != null && customCmdsJson.isNotEmpty) {
      setState(() {
        _quickCommands = customCmdsJson
            .map((c) => Map<String, String>.from(jsonDecode(c)))
            .toList();
      });
    }

    _addLog('Loaded profiles and preferences.', color: Colors.cyanAccent);
  }

  Future<void> _loadProfileToControllers(String profileId) async {
    final profile = _profiles.firstWhere((p) => p.id == profileId,
        orElse: () => _profiles.first);
    setState(() {
      _activeProfileId = profile.id;
      _hostController.text = profile.host;
      _portController.text = profile.port;
      _userController.text = profile.username;
    });
    final savedPassword =
        await _secureStorage.read(key: 'ssh_password_${profile.id}');
    if (savedPassword != null) {
      _passwordController.text = savedPassword;
    } else {
      _passwordController.clear();
    }
  }

  Future<void> _saveCurrentProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final profile =
        _profiles.firstWhere((p) => p.id == _activeProfileId, orElse: () {
      final newP = SSHProfile(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: 'Profile ${_profiles.length + 1}',
          host: '',
          port: '8022',
          username: '');
      _profiles.add(newP);
      return newP;
    });

    profile.host = _hostController.text.trim();
    profile.port = _portController.text.trim();
    profile.username = _userController.text.trim();

    await prefs.setStringList(
        'ssh_profiles', _profiles.map((p) => jsonEncode(p.toJson())).toList());
    await prefs.setString('active_profile_id', profile.id);
    await _secureStorage.write(
        key: 'ssh_password_${profile.id}', value: _passwordController.text);
    _addLog('Profile "${profile.name}" saved securely.',
        color: Colors.greenAccent);
  }

  void _addLog(String text, {Color color = Colors.white}) {
    setState(() {
      _logs.add(LogEntry(text, color: color));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _connect() async {
    if (_isConnecting) return;

    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 8022;
    final username = _userController.text.trim();
    final password = _passwordController.text;

    if (host.isEmpty || username.isEmpty) {
      _addLog('ERROR: Host and Username cannot be empty.',
          color: Colors.redAccent);
      return;
    }

    await _saveCurrentProfile();
    await _connectTo(host, port, username, password);
  }

  Future<void> _connectTo(
    String host,
    int port,
    String username,
    String password,
  ) async {
    if (_isConnecting) return;

    setState(() {
      _isConnecting = true;
      _isConnected = false;
    });

    _addLog('Connecting to $username@$host:$port over SSH...',
        color: Colors.yellowAccent);

    try {
      final socket = await SSHSocket.connect(
        host,
        port,
        timeout: const Duration(seconds: 10),
      );

      final client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: () => password,
      );
      _client = client;

      await client.authenticated;

      if (!mounted) return;
      setState(() {
        _isConnected = true;
        _isConnecting = false;
      });

      _addLog('SUCCESS: Connected to $username@$host:$port!',
          color: Colors.greenAccent);
      _executeCommand('uname -a && uptime');
    } catch (error) {
      try {
        _client?.close();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _client = null;
        _isConnected = false;
        _isConnecting = false;
      });

      final message = error.toString().toLowerCase();
      String guidance;
      if (message.contains('timed out') || message.contains('timeout')) {
        guidance =
            'Connection timed out. Check that Tailscale is connected and the host/port are reachable.';
      } else if (message.contains('authentication') ||
          message.contains('password') ||
          message.contains('permission denied')) {
        guidance =
            'Authentication failed. Check the username, password, and SSH server authentication settings.';
      } else if (message.contains('refused') ||
          message.contains('unreachable')) {
        guidance =
            'Host or port is unreachable. Verify the Tailscale address and SSH port.';
      } else {
        guidance =
            'Check that Tailscale is connected on this phone and that the SSH server is running.';
      }
      _addLog('ERROR: Connection failed: $error', color: Colors.redAccent);
      _addLog('HINT: $guidance', color: Colors.orangeAccent);
    }
  }

  Future<void> _disconnect() async {
    try {
      _client?.close();
    } catch (_) {}
    setState(() {
      _client = null;
      _isConnected = false;
    });
    _addLog('Disconnected from SSH server.', color: Colors.orangeAccent);
  }

  Future<String?> _promptForPassword(String host) async {
    final passwordController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Password for $host'),
        content: TextField(
          controller: passwordController,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'SSH Password',
            helperText: 'The password is not written to the terminal log.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.pop(dialogContext, passwordController.text),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    passwordController.dispose();
    return result;
  }

  Future<void> _handleTerminalInput(String commandStr) async {
    final input = commandStr.trim();
    if (input.isEmpty) return;

    final match = RegExp(
      r'^connect\s+(\S+)\s+(\d{1,5})\s+(\S+)(?:\s+(.*))?$',
      caseSensitive: false,
    ).firstMatch(input);

    if (match == null) {
      if (!_isConnected) {
        _addLog(
          'Local command not recognized. Use: connect <host> <port> <username> [password]',
          color: Colors.orangeAccent,
        );
      }
      await _executeCommand(input);
      return;
    }

    final host = match.group(1)!;
    final port = int.parse(match.group(2)!);
    final username = match.group(3)!;
    final inlinePassword = match.group(4)?.trim();

    _addLog('\$ connect $host $port $username', color: const Color(0xFF38BDF8));

    if (port < 1 || port > 65535) {
      _addLog('ERROR: Port must be between 1 and 65535.',
          color: Colors.redAccent);
      return;
    }

    final password = inlinePassword ?? await _promptForPassword(host);
    if (password == null) {
      _addLog('Connection cancelled.', color: Colors.orangeAccent);
      return;
    }

    _hostController.text = host;
    _portController.text = '$port';
    _userController.text = username;
    _passwordController.text = password;

    await _saveCurrentProfile();
    await _connectTo(host, port, username, password);
  }

  Future<void> _executeCommand(String commandStr) async {
    if (_client == null || !_isConnected) {
      _addLog('Error: Not connected to SSH server.', color: Colors.redAccent);
      return;
    }

    if (commandStr.trim().isEmpty) return;

    _addLog('\$ $commandStr', color: const Color(0xFF38BDF8));

    try {
      final session = await _client!.execute(commandStr);

      session.stdout.listen((data) {
        final output = String.fromCharCodes(data).trimRight();
        if (output.isNotEmpty) {
          _addLog(output, color: Colors.white);
        }
      });

      session.stderr.listen((data) {
        final errorOutput = String.fromCharCodes(data).trimRight();
        if (errorOutput.isNotEmpty) {
          _addLog(errorOutput, color: Colors.redAccent);
        }
      });

      await session.done;
      final exitCode = session.exitCode ?? 0;
      if (exitCode != 0) {
        _addLog('[Process exited with code $exitCode]',
            color: Colors.orangeAccent);
      }
    } catch (e) {
      _addLog('Execution error: $e', color: Colors.redAccent);
    }
  }

  void _showAddCommandDialog() {
    final nameController = TextEditingController();
    final cmdController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Custom Command Macro'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Macro Name')),
            const SizedBox(height: 10),
            TextField(
                controller: cmdController,
                decoration: const InputDecoration(
                    labelText: 'Shell Command / Agent Task')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty &&
                  cmdController.text.isNotEmpty) {
                setState(() {
                  _quickCommands.add({
                    'name': nameController.text.trim(),
                    'cmd': cmdController.text.trim()
                  });
                });
                final prefs = await SharedPreferences.getInstance();
                await prefs.setStringList('custom_quick_cmds',
                    _quickCommands.map((c) => jsonEncode(c)).toList());
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                _addLog('Added macro: ${nameController.text}',
                    color: Colors.greenAccent);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showAddProfileDialog() {
    final nameController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New SSH Profile'),
        content: TextField(
            controller: nameController,
            decoration: const InputDecoration(
                labelText: 'Profile Name (e.g. VPS / Termux)')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (nameController.text.isNotEmpty) {
                final newP = SSHProfile(
                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                  name: nameController.text.trim(),
                  host: '',
                  port: '8022',
                  username: '',
                );
                setState(() {
                  _profiles.add(newP);
                  _activeProfileId = newP.id;
                });
                _loadProfileToControllers(newP.id);
                await _saveCurrentProfile();
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _commandController.dispose();
    _scrollController.dispose();
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.terminal, color: Color(0xFF38BDF8)),
            const SizedBox(width: 10),
            const Text('Termux SSH Bridge',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _isConnected
                    ? Colors.green.withOpacity(0.2)
                    : _isConnecting
                        ? Colors.orange.withOpacity(0.2)
                        : Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _isConnected
                      ? Colors.green
                      : _isConnecting
                          ? Colors.orange
                          : Colors.red,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isConnected
                          ? Colors.greenAccent
                          : _isConnecting
                              ? Colors.orangeAccent
                              : Colors.redAccent,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _isConnected
                        ? 'ONLINE'
                        : _isConnecting
                            ? 'CONNECTING'
                            : 'OFFLINE',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _isConnected
                          ? Colors.greenAccent
                          : _isConnecting
                              ? Colors.orangeAccent
                              : Colors.redAccent,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF38BDF8),
          tabs: const [
            Tab(icon: Icon(Icons.settings, size: 18), text: 'Profiles'),
            Tab(icon: Icon(Icons.bolt, size: 18), text: 'Macros'),
            Tab(icon: Icon(Icons.computer, size: 18), text: 'Terminal'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildProfilesAndConnectionTab(),
          _buildMacrosTab(),
          _buildTerminalTab(),
        ],
      ),
    );
  }

  Widget _buildProfilesAndConnectionTab() {
    return ListView(
      padding: const EdgeInsets.all(16.0),
      children: [
        Card(
          elevation: 3,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(14.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('SSH Connection Profiles',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: Color(0xFF38BDF8))),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline, size: 22),
                      tooltip: 'Add Profile',
                      onPressed: _showAddProfileDialog,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _activeProfileId,
                  decoration: const InputDecoration(
                      border: OutlineInputBorder(), isDense: true),
                  items: _profiles
                      .map((p) =>
                          DropdownMenuItem(value: p.id, child: Text(p.name)))
                      .toList(),
                  onChanged: (val) {
                    if (val != null) {
                      _loadProfileToControllers(val);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 3,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Host & Credentials',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: Color(0xFF38BDF8))),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _hostController,
                        decoration: const InputDecoration(
                            labelText: 'Host / Tailscale IP',
                            hintText: 'e.g. 100.x.x.x',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.network_ping),
                            isDense: true),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 1,
                      child: TextField(
                        controller: _portController,
                        decoration: const InputDecoration(
                            labelText: 'Port',
                            hintText: '8022',
                            border: OutlineInputBorder(),
                            isDense: true),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _userController,
                        decoration: const InputDecoration(
                            labelText: 'Username',
                            hintText: 'e.g. u0_a123',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.person),
                            isDense: true),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _passwordController,
                        decoration: const InputDecoration(
                            labelText: 'Password / Key',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.lock),
                            isDense: true),
                        obscureText: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isConnecting
                        ? null
                        : (_isConnected ? _disconnect : _connect),
                    icon: Icon(_isConnected ? Icons.logout : Icons.login),
                    label: Text(_isConnecting
                        ? 'Connecting...'
                        : (_isConnected
                            ? 'Disconnect SSH'
                            : 'Connect to Host')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isConnected
                          ? Colors.redAccent.shade700
                          : const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 3,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Terminal Font Size',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: Color(0xFF38BDF8))),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Text('Size: '),
                    Expanded(
                      child: Slider(
                        value: _fontSize,
                        min: 10.0,
                        max: 20.0,
                        divisions: 10,
                        label: _fontSize.toStringAsFixed(1),
                        onChanged: (val) => setState(() => _fontSize = val),
                      ),
                    ),
                    Text('${_fontSize.toStringAsFixed(1)} pt'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMacrosTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Coding Agent & Quick Macros',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Color(0xFF38BDF8))),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _showAddCommandDialog,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Macro'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    foregroundColor: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: _quickCommands.length,
              itemBuilder: (context, index) {
                final cmd = _quickCommands[index];
                return Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  elevation: 2,
                  child: ListTile(
                    title: Text(cmd['name']!,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(cmd['cmd']!,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12)),
                    trailing: IconButton(
                      icon: const Icon(Icons.play_arrow,
                          color: Color(0xFF38BDF8)),
                      tooltip: 'Run Command',
                      onPressed: _isConnected
                          ? () => _executeCommand(cmd['cmd']!)
                          : null,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalTab() {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          Row(
            children: [
              Text('Live Logs (${_logs.length})',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: Colors.grey),
                tooltip: 'Clear Logs',
                onPressed: () => setState(() => _logs.clear()),
              ),
            ],
          ),
          const Divider(height: 4),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF090D16),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade700),
              ),
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  final log = _logs[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2.0),
                    child: SelectableText(
                      '[${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}] ${log.text}',
                      style: TextStyle(
                          color: log.color,
                          fontSize: _fontSize,
                          fontFamily: 'monospace'),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _commandController,
                  enabled: !_isConnecting,
                  style:
                      TextStyle(fontFamily: 'monospace', fontSize: _fontSize),
                  decoration: InputDecoration(
                    hintText: _isConnected
                        ? 'Enter bash command or coding agent task...'
                        : 'Or type: connect <host> <port> <username>',
                    hintStyle: const TextStyle(color: Colors.grey),
                    border: const OutlineInputBorder(),
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                  ),
                  onSubmitted: (value) {
                    _handleTerminalInput(value);
                    _commandController.clear();
                  },
                ),
              ),
              const SizedBox(width: 8),
              if (!_isConnected)
                ElevatedButton.icon(
                  onPressed: _isConnecting
                      ? null
                      : () {
                          final command = _commandController.text.trim();
                          if (command.isEmpty) {
                            _connect();
                          } else {
                            _handleTerminalInput(command);
                            _commandController.clear();
                          }
                        },
                  icon: const Icon(Icons.login, size: 18),
                  label: const Text('Connect'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                  ),
                )
              else
                ElevatedButton(
                  onPressed: () {
                    _executeCommand(_commandController.text);
                    _commandController.clear();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF38BDF8),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                  child: const Text('Send',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
