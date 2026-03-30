import 'dart:ui';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseService.init();
  runApp(const HelmetApp());
}

/* ================= PERMISSIONS ================= */

Future<bool> requestBlePermissions() async {
  final statuses = await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.bluetoothAdvertise,
  ].request();
  return statuses.values.every((s) => s.isGranted);
}

/* ================= SUPABASE SERVICE ================= */

class SupabaseService {
  static const _url     = 'https://hoczdzegcfhcgkajflhw.supabase.co';
  static const _anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhvY3pkemVnY2ZoY2drYWpmbGh3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAzNjgzODYsImV4cCI6MjA4NTk0NDM4Nn0.SMJnHWU17DVM_0IlAuLjjE8fjjymm9DOQWz_ik-tpjY';

  static SupabaseClient get client => Supabase.instance.client;

  static Future<void> init() async {
    await Supabase.initialize(url: _url, anonKey: _anonKey);
  }

  // ── Auth ──────────────────────────────────────────────────────────────────

  /// Signs up with Supabase Auth and stores helmetCode in `profiles` table.
  static Future<String?> signup(
      String email, String password, String helmetCode) async {
    try {
      final res = await client.auth.signUp(
        email: email,
        password: password,
      );
      final uid = res.user?.id;
      if (uid == null) return 'Signup failed — no user returned';

      // Upsert into a `profiles` table: id (uuid FK), helmet_code (text)
      await client.from('profiles').upsert({
        'id': uid,
        'email': email,
        'helmet_code': helmetCode,
      });
      return null; // success
    } on AuthException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Signs in with Supabase Auth, then fetches helmetCode from `profiles`.
  static Future<({String? error, Map<String, dynamic>? user})> login(
      String email, String password) async {
    try {
      final res = await client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      final uid = res.user?.id;
      if (uid == null) return (error: 'Login failed', user: null);

      final profile = await client
          .from('profiles')
          .select('email, helmet_code')
          .eq('id', uid)
          .maybeSingle();

      return (
        error: null,
        user: {
          'email': profile?['email'] ?? email,
          'helmetCode': profile?['helmet_code'] ?? '',
        }
      );
    } on AuthException catch (e) {
      return (error: e.message, user: null);
    } catch (e) {
      return (error: e.toString(), user: null);
    }
  }

  static Future<void> logout() async {
    await client.auth.signOut();
  }
}

/* ================= SESSION ================= */

class UserSession {
  static String email = '';
  static String helmetCode = '';
  static String role = 'OWNER';
}

/* ================= BLE SERVICE ================= */

class BleService {
  static const String _deviceName       = 'HelmetESP32';
  static const String _serviceUuid      = '12345678-1234-1234-1234-1234567890ab';
  static const String _characteristicUuid = 'abcd1234-ab12-ab12-ab12-abcdef123456';

  static BluetoothDevice?        _device;
  static BluetoothCharacteristic? _char;

  static Future<String?> connect() async {
    try {
      // 1. Check BLE support
      if (!await FlutterBluePlus.isSupported) {
        return 'Bluetooth not supported on this device';
      }

      // 2. Check adapter state
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        await FlutterBluePlus.turnOn();
        final ready = await FlutterBluePlus.adapterState
            .where((s) => s == BluetoothAdapterState.on)
            .first
            .timeout(
              const Duration(seconds: 5),
              onTimeout: () => BluetoothAdapterState.off,
            );
        if (ready != BluetoothAdapterState.on) {
          return 'Please enable Bluetooth and try again';
        }
      }

      // 3. Scan for ESP32
      await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 6));

      BluetoothDevice? found;
      await for (final results in FlutterBluePlus.scanResults) {
        for (final r in results) {
          if (r.device.platformName == _deviceName) {
            found = r.device;
            break;
          }
        }
        if (found != null) break;
      }
      await FlutterBluePlus.stopScan();

      if (found == null) {
        return 'ESP32 not found — is it powered on and not connected to another device?';
      }

      // 4. Connect
      await found.connect(timeout: const Duration(seconds: 8));
      _device = found;

      // 5. Discover characteristic
      final services = await found.discoverServices();
      for (final svc in services) {
        if (svc.uuid.toString() == _serviceUuid) {
          for (final c in svc.characteristics) {
            if (c.uuid.toString() == _characteristicUuid) {
              _char = c;
              break;
            }
          }
        }
      }

      if (_char == null) {
        await found.disconnect();
        return 'Connected but characteristic not found';
      }
      return null; // success

    } catch (e) {
      return 'BLE error: $e';
    }
  }

  /// Write 0x01 → ESP32 starts blinking / MPU monitoring
  static Future<void> activate(BuildContext context) async {
    final err = await _sendCommand(0x01);
    if (err != null) {
      final connErr = await connect();
      if (connErr != null) { snack(context, connErr); return; }
      final err2 = await _sendCommand(0x01);
      if (err2 != null) { snack(context, err2); return; }
    }
    snack(context, 'Helmet sensor activated ✓');
  }

  /// Write 0x00 → ESP32 stops blinking / MPU monitoring
  static Future<void> deactivate(BuildContext context) async {
    final err = await _sendCommand(0x00);
    if (err != null) snack(context, err);
    else snack(context, 'Helmet sensor deactivated');
  }

  static Future<String?> _sendCommand(int byte) async {
    if (_char == null) return 'Not connected to ESP32';
    try {
      await _char!.write([byte], withoutResponse: false);
      return null;
    } catch (e) {
      _char = null;
      return 'Send failed: $e';
    }
  }

  static Future<void> disconnect() async {
    await _device?.disconnect();
    _device = null;
    _char  = null;
  }
}

/* ================= APP ROOT ================= */

class HelmetApp extends StatelessWidget {
  const HelmetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: const LoginPage(),
    );
  }
}

/* ================= LOGIN ================= */

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final email    = TextEditingController();
  final password = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: glassCard(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sports_motorsports,
                  size: 60, color: Colors.cyanAccent),
              const SizedBox(height: 16),
              cyberField("Email", controller: email),
              const SizedBox(height: 12),
              cyberField("Password",
                  controller: password, obscure: true),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: neonButton(),
                  onPressed: () async {
                    final result = await SupabaseService.login(
                        email.text, password.text);
                    if (result.error == null && result.user != null) {
                      UserSession.email      = result.user!['email'];
                      UserSession.helmetCode = result.user!['helmetCode'];
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const HomePage()),
                      );
                    } else {
                      snack(context, result.error ?? "Invalid login");
                    }
                  },
                  child: const Text("LOGIN"),
                ),
              ),
              const SizedBox(height: 12),
              socialButton(
                icon: Icons.g_mobiledata,
                text: "Sign in with Google",
                onTap: () => snack(context, "UI only"),
              ),
              if (Platform.isIOS)
                socialButton(
                  icon: Icons.apple,
                  text: "Sign in with Apple",
                  onTap: () => snack(context, "UI only"),
                ),
              TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const SignupPage()),
                ),
                child: const Text("Create account"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ================= SIGNUP ================= */

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> {
  final email    = TextEditingController();
  final password = TextEditingController();
  final helmet   = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: glassCard(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sports_motorsports,
                  size: 60, color: Colors.cyanAccent),
              const SizedBox(height: 16),
              cyberField("Email", controller: email),
              const SizedBox(height: 12),
              cyberField("Password",
                  controller: password, obscure: true),
              const SizedBox(height: 12),
              cyberField("Helmet Code", controller: helmet),
              const SizedBox(height: 20),
              ElevatedButton(
                style: neonButton(),
                onPressed: () async {
                  final err = await SupabaseService.signup(
                      email.text, password.text, helmet.text);
                  if (err == null) {
                    snack(context, "Signup successful — check your email to confirm");
                    Navigator.pop(context);
                  } else {
                    snack(context, err);
                  }
                },
                child: const Text("SIGN UP"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ================= HOME PAGE ================= */

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool helmetSecured  = false;
  bool _bleConnected  = false;
  bool _bleConnecting = false;

  Future<void> _toggle() async {
  final nowSecured = !helmetSecured;

  if (nowSecured) {
    // ── SECURING: connect BLE ──
    final granted = await requestBlePermissions();
    if (!granted) {
      snack(context, 'Bluetooth permissions denied — enable in Settings');
      return;
    }

    setState(() => _bleConnecting = true);
    snack(context, 'Scanning for ESP32…');
    final err = await BleService.connect();
    setState(() => _bleConnecting = false);

    if (err != null) {
      snack(context, err);
      return;
    }

    _bleConnected = true;
    setState(() => helmetSecured = true);
    await BleService.activate(context);

  } else {
    // ── UNSECURING: disconnect BLE ──
    setState(() => helmetSecured = false);
    await BleService.deactivate(context);
    await BleService.disconnect();   // ← fully disconnects from ESP32
    _bleConnected = false;
    snack(context, 'Helmet unsecured — Bluetooth disconnected');
  }
}

  @override
  Widget build(BuildContext context) {
    final color = helmetSecured ? Colors.cyanAccent : Colors.redAccent;

    return Scaffold(
      bottomNavigationBar: const AppNav(index: 0),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Saturday, Jan 31, 2026   14:24 IST",
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 30),

              GestureDetector(
                onTap: _bleConnecting ? null : _toggle,
                child: _bleConnecting
                    ? SizedBox(
                        width: 170,
                        height: 170,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            statusRing(Colors.grey),
                            const CircularProgressIndicator(
                                color: Colors.cyanAccent),
                          ],
                        ),
                      )
                    : statusRing(color),
              ),

              const SizedBox(height: 16),
              Text(
                helmetSecured ? "SECURED" : "UNSECURED",
                style: TextStyle(fontSize: 26, color: color),
              ),
              const SizedBox(height: 30),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: Icon(Icons.lock, color: color, size: 30),
                    onPressed: _bleConnecting ? null : _toggle,
                  ),
                  const Icon(Icons.notifications,
                      color: Colors.cyanAccent),
                  const Icon(Icons.location_on,
                      color: Colors.cyanAccent),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ================= TRACK PAGE ================= */

class TrackPage extends StatelessWidget {
  const TrackPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: const AppNav(index: 1),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 10),
            const Text("Helmet Location",
                style: TextStyle(fontSize: 22)),
            Expanded(
              child: Stack(
                children: [
                  const CyberMap(),
                  Container(
                    color: Colors.black.withOpacity(0.75),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.location_off,
                              color: Colors.cyanAccent, size: 56),
                          const SizedBox(height: 16),
                          const Text(
                            "Not Available",
                            style: TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              color: Colors.cyanAccent,
                              letterSpacing: 2,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            "GPS tracking coming soon",
                            style: TextStyle(
                                color: Colors.grey[400], fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ================= MY ACCOUNT PAGE ================= */

class MyAccountPage extends StatelessWidget {
  const MyAccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      bottomNavigationBar: const AppNav(index: 2),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text("My Account",
                style: TextStyle(fontSize: 26)),
            const SizedBox(height: 20),
            Row(
              children: [
                const CircleAvatar(radius: 35),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(UserSession.email),
                    Text(
                      "Helmet: ${UserSession.helmetCode}",
                      style: const TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            glassSection("Profile Information", [
              listTile(Icons.email,    UserSession.email),
              listTile(Icons.verified, UserSession.helmetCode),
              listTile(Icons.security, UserSession.role),
            ]),
            glassSection("My Devices", [
              listTile(
                Icons.sports_motorsports,
                "Helmet (Active)",
                trailing: const Icon(Icons.battery_full,
                    color: Colors.green),
              ),
            ]),
            glassSection("App Preferences", [
              switchTile("Notification Preferences"),
            ]),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.cyanAccent,
                  foregroundColor: Colors.black),
              onPressed: () async {
                await SupabaseService.logout();
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const LoginPage()),
                );
              },
              child: const Text("Log Out"),
            ),
          ],
        ),
      ),
    );
  }
}

/* ================= NAV ================= */

class AppNav extends StatelessWidget {
  final int index;
  const AppNav({super.key, required this.index});

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: index,
      backgroundColor: Colors.black,
      selectedItemColor: Colors.cyanAccent,
      unselectedItemColor: Colors.grey,
      onTap: (i) {
        if (i == index) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => i == 0
                ? const HomePage()
                : i == 1
                    ? const TrackPage()
                    : const MyAccountPage(),
          ),
        );
      },
      items: const [
        BottomNavigationBarItem(
            icon: Icon(Icons.shield), label: "Home"),
        BottomNavigationBarItem(
            icon: Icon(Icons.map), label: "Track"),
        BottomNavigationBarItem(
            icon: Icon(Icons.person), label: "Account"),
      ],
    );
  }
}

/* ================= MAP ================= */

class CyberMap extends StatelessWidget {
  const CyberMap({super.key});

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      options: const MapOptions(
        initialCenter: LatLng(12.9716, 77.5946),
        initialZoom: 16,
      ),
      children: [
        TileLayer(
          urlTemplate:
              "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
          userAgentPackageName: 'helmet.app',
        ),
        const MarkerLayer(
          markers: [
            Marker(
              point: LatLng(12.9716, 77.5946),
              width: 60,
              height: 60,
              child: Icon(Icons.location_pin,
                  color: Colors.redAccent, size: 50),
            ),
          ],
        ),
      ],
    );
  }
}

/* ================= UI HELPERS ================= */

Widget cyberField(String hint,
    {TextEditingController? controller, bool obscure = false}) {
  return TextField(
    controller: controller,
    obscureText: obscure,
    decoration: InputDecoration(
      hintText: hint,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.cyanAccent),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.cyanAccent),
      ),
    ),
  );
}

Widget glassCard(Widget child) {
  return ClipRRect(
    borderRadius: BorderRadius.circular(20),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.07),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: Colors.cyanAccent.withOpacity(0.3)),
        ),
        child: child,
      ),
    ),
  );
}

Widget statusRing(Color color) {
  return Container(
    width: 170,
    height: 170,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: color, width: 4),
      boxShadow: [
        BoxShadow(
            color: color.withOpacity(0.6), blurRadius: 20),
      ],
    ),
    child: Center(
      child: Icon(Icons.sports_motorsports,
          size: 60, color: color),
    ),
  );
}

Widget glassSection(String title, List<Widget> children) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: glassCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    ),
  );
}

Widget listTile(IconData icon, String text, {Widget? trailing}) {
  return ListTile(
    leading: Icon(icon, color: Colors.cyanAccent),
    title: Text(text),
    trailing: trailing,
  );
}

Widget switchTile(String text) {
  return SwitchListTile(
    value: true,
    onChanged: (_) {},
    activeColor: Colors.cyanAccent,
    title: Text(text),
  );
}

ButtonStyle neonButton() => ElevatedButton.styleFrom(
    backgroundColor: Colors.cyanAccent,
    foregroundColor: Colors.black);

Widget socialButton(
    {required IconData icon,
    required String text,
    required VoidCallback onTap}) {
  return Padding(
    padding: const EdgeInsets.only(top: 8),
    child: ElevatedButton.icon(
      icon: Icon(icon),
      label: Text(text),
      onPressed: onTap,
    ),
  );
}

void snack(BuildContext c, String t) =>
    ScaffoldMessenger.of(c)
        .showSnackBar(SnackBar(content: Text(t)));