import 'dart:async';
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
        scaffoldBackgroundColor: const Color(0xFF0F172A), // Slate 900
        primaryColor: const Color(0xFF38BDF8), // Sky 400
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF818CF8), // Indigo 400
          surface: Color(0xFF1E293B), // Slate 800
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

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  // Controllers for Connection Settings (allowing any user, host, and port)
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8022');
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();

  // Controllers for Command Execution
  final _commandController = TextEditingController();

  final _secureStorage = const FlutterSecureStorage();
  
  SSHClient? _client;
  bool _isConnected = false;
  bool _isConnecting = false;
  
  final List<LogEntry> _logs = [];
  final ScrollController _scrollController = ScrollController();

  // Quick preset coding agent / termux commands
  final List<Map<String, String>> _quickCommands = [
    {'name': 'Whoami & Env', 'cmd': 'whoami && uname -a && pwd'},
    {'name': 'PRoot Info', 'cmd': 'proot --version || echo "PRoot active via standard termux"'},
    {'name': 'Disk Usage', 'cmd': 'df -h'},
    {'name': 'Tailscale Status', 'cmd': 'tailscale status || echo "Tailscale service running on host"'},
    {'name': 'Coding Agent (Git Status)', 'cmd': 'git status || echo "Not a git repo"'},
    {'name': 'Python Agent Test', 'cmd': 'python3 --version && pip list'},
  ];

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _hostController.text = prefs.getString('ssh_host') ?? '';
      _portController.text = prefs.getString('ssh_port') ?? '8022';
      _userController.text = prefs.getString('ssh_user') ?? '';
    });
    
    final savedPassword = await _secureStorage.read(key: 'ssh_password');
    if (savedPassword != null) {
      _passwordController.text = savedPassword;
    }
    _addLog('Loaded saved configurations.', color: Colors.cyanAccent);
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ssh_host', _hostController.text.trim());
    await prefs.setString('ssh_port', _portController.text.trim());
    await prefs.setString('ssh_user', _userController.text.trim());
    await _secureStorage.write(key: 'ssh_password', value: _passwordController.text);
    _addLog('Credentials securely stored.', color: Colors.greenAccent);
  }

  void _addLog(String text, {Color color = Colors.white}) {
    setState(() {
      _logs.add(LogEntry(text, color: color));
    });
    // Auto scroll to bottom of terminal log
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

    if (host.isEmpty) {
      _addLog('ERROR: Please enter a valid SSH host or Tailscale IP.', color: Colors.redAccent);
      return;
    }

    if (username.isEmpty) {
      _addLog('ERROR: Please enter an SSH username.', color: Colors.redAccent);
      return;
    }
    
    setState(() {
      _isConnecting = true;
    });

    await _saveCredentials();

    _addLog('Connecting to $username@$host:$port over SSH / Tailscale...', color: Colors.yellowAccent);

    try {
      final socket = await SSHSocket.connect(
        host,
        port,
        timeout: const Duration(seconds: 10),
      );

      _client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: () => password,
      );

      // Wait for authentication
      await _client!.authenticated;

      setState(() {
        _isConnected = true;
        _isConnecting = false;
      });

      _addLog('SUCCESS: Connected and authenticated to $username@$host:$port!', color: Colors.greenAccent);
      
      // Run initial Greeting command
      _executeCommand('uname -a && uptime');

    } catch (e) {
      _addLog('ERROR: Connection failed: $e', color: Colors.redAccent);
      setState(() {
        _isConnected = false;
        _isConnecting = false;
      });
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

  Future<void> _executeCommand(String commandStr) async {
    if (_client == null || !_isConnected) {
      _addLog('Error: Not connected to SSH server.', color: Colors.redAccent);
      return;
    }

    if (commandStr.trim().isEmpty) return;

    _addLog('\$ $commandStr', color: const Color(0xFF38BDF8));

    try {
      final session = await _client!.execute(commandStr);
      
      // Read stdout
      session.stdout.listen((data) {
        final output = String.fromCharCodes(data).trimRight();
        if (output.isNotEmpty) {
          _addLog(output, color: Colors.white);
        }
      });

      // Read stderr
      session.stderr.listen((data) {
        final errorOutput = String.fromCharCodes(data).trimRight();
        if (errorOutput.isNotEmpty) {
          _addLog(errorOutput, color: Colors.redAccent);
        }
      });

      await session.done;
      final exitCode = session.exitCode ?? 0;
      if (exitCode != 0) {
        _addLog('[Process exited with code $exitCode]', color: Colors.orangeAccent);
      }
    } catch (e) {
      _addLog('Execution error: $e', color: Colors.redAccent);
    }
  }

  @override
  void dispose() {
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
            const SizedBox(width: 12),
            const Text('Termux SSH Bridge', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _isConnected ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _isConnected ? Colors.green : Colors.red),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isConnected ? 'CONNECTED' : 'DISCONNECTED',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _isConnected ? Colors.greenAccent : Colors.redAccent,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          bool isWide = constraints.maxWidth > 900;
          return isWide ? _buildWideLayout(context) : _buildMobileLayout(context);
        },
      ),
    );
  }

  Widget _buildConnectionCard() {
    return Card(
      color: const Color(0xFF1E293B),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'SSH & Tailscale Connection',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8)),
            ),
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
                      isDense: true,
                    ),
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
                      isDense: true,
                    ),
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
                      labelText: 'SSH Username',
                      hintText: 'e.g. u0_a123',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.person),
                      isDense: true,
                    ),
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
                      isDense: true,
                    ),
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
                    : (_isConnected ? 'Disconnect SSH' : 'Connect to Host')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isConnected ? Colors.redAccent.shade700 : const Color(0xFF0284C7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActionsCard() {
    return Card(
      color: const Color(0xFF1E293B),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Coding Agent & Termux Presets',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF38BDF8)),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8.0,
              runSpacing: 8.0,
              children: _quickCommands.map((preset) {
                return ActionChip(
                  label: Text(preset['name']!, style: const TextStyle(fontSize: 12)),
                  backgroundColor: const Color(0xFF334155),
                  onPressed: _isConnected ? () => _executeCommand(preset['cmd']!) : null,
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTerminalConsoleCard() {
    return Card(
      color: const Color(0xFF090D16),
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF334155)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Terminal Output & Logs',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.grey),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18, color: Colors.grey),
                  tooltip: 'Clear Logs',
                  onPressed: () => setState(() => _logs.clear()),
                ),
              ],
            ),
            const Divider(color: Color(0xFF334155)),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                itemCount: _logs.length,
                itemBuilder: (context, index) {
                  final log = _logs[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2.0),
                    child: SelectableText(
                      '[${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}] ${log.text}',
                      style: TextStyle(color: log.color, fontSize: 13, fontFamily: 'monospace'),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _commandController,
                    enabled: _isConnected,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                    decoration: InputDecoration(
                      hintText: _isConnected ? 'Enter bash command or coding agent task...' : 'Connect to execute commands',
                      hintStyle: const TextStyle(color: Colors.grey),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                    ),
                    onSubmitted: (value) {
                      _executeCommand(value);
                      _commandController.clear();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isConnected
                      ? () {
                          _executeCommand(_commandController.text);
                          _commandController.clear();
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF38BDF8),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  child: const Text('Send', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWideLayout(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 380,
            child: Column(
              children: [
                _buildConnectionCard(),
                const SizedBox(height: 16),
                Expanded(child: _buildQuickActionsCard()),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _buildTerminalConsoleCard(),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12.0),
      child: Column(
        children: [
          ExpansionTile(
            title: const Text('Connection & Presets', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            collapsedBackgroundColor: const Color(0xFF1E293B),
            backgroundColor: const Color(0xFF1E293B),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            children: [
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  children: [
                    _buildConnectionCard(),
                    const SizedBox(height: 12),
                    _buildQuickActionsCard(),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: _buildTerminalConsoleCard(),
          ),
        ],
      ),
    );
  }
}
