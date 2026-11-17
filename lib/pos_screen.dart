import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';

import 'barcode_listener.dart';
import 'escpos.dart';
import 'models.dart';
import 'numpad.dart';
import 'onscreen_keyboard.dart';
import 'plu_import.dart';
import 'product_store.dart';
import 'receipt.dart';
import 'settings.dart';
import 'sounds.dart';
import 'storage.dart';

class PosScreen extends StatefulWidget {
  const PosScreen({super.key});

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final store = ProductStore();
  Settings settings = Settings();
  final cart = <CartLine>[];
  final input = TextEditingController();
  final inputFocus = FocusNode();
  late final BarcodeListener scanner;

  List<Product> results = [];
  bool _showKeyboard = false;
  String? _errorCode;
  String? _errorRaw;
  Timer? _errorTimer;
  int todayTotal = 0;
  bool loading = true;
  DateTime _lastScanAt = DateTime.fromMillisecondsSinceEpoch(0);

  int get total => cart.fold(0, (s, l) => s + l.totalCents);

  @override
  void initState() {
    super.initState();
    scanner = BarcodeListener(
      onScan: _onScan,
      // Ignore scans while a dialog is open.
      isActive: () => mounted && (ModalRoute.of(context)?.isCurrent ?? true),
    );
    initSounds();
    _load();
  }

  Future<void> _load() async {
    await store.load();
    settings = await Settings.load();
    todayTotal = await SalesLog.todayTotal();
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    _errorTimer?.cancel();
    scanner.dispose();
    input.dispose();
    inputFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- scanning

  void _onScan(String code) {
    _lastScanAt = DateTime.now();
    input.clear();
    setState(() => results = []);
    final clean = code.trim();
    // QR codes and other non-numeric codes are never products.
    final r = RegExp(r'^\d+$').hasMatch(clean) ? resolveScan(clean, store) : null;
    if (r == null) {
      _notFound(clean.length > 30 ? '${clean.substring(0, 30)}…' : clean,
          raw: clean);
      return;
    }
    _addProduct(r.product, embeddedPriceCents: r.embeddedPriceCents);
  }

  void _onSubmit(String text) {
    // The scanner already handled this Enter.
    if (DateTime.now().difference(_lastScanAt).inMilliseconds < 300) return;
    final t = text.trim();
    if (t.isEmpty) return;

    if (RegExp(r'^\d+$').hasMatch(t)) {
      Product? p;
      int? embedded;
      if (t.length <= 5) {
        p = store.byPlu(int.parse(t)); // typed PLU number
      } else {
        final r = resolveScan(t, store); // typed barcode
        p = r?.product;
        embedded = r?.embeddedPriceCents;
      }
      _clearInput();
      if (p == null) {
        _notFound(t);
      } else {
        _addProduct(p, embeddedPriceCents: embedded);
      }
      return;
    }
    if (results.length == 1) {
      final p = results.first;
      _clearInput();
      _addProduct(p);
    }
  }

  void _onInputChanged(String text) {
    final t = text.trim();
    setState(() {
      results = (t.length >= 2 && !RegExp(r'^\d+$').hasMatch(t))
          ? store.search(t)
          : [];
    });
  }

  void _clearInput() {
    input.clear();
    setState(() => results = []);
    inputFocus.requestFocus();
  }

  void _notFound(String code, {String? raw}) {
    playError();
    _errorTimer?.cancel();
    setState(() {
      _errorCode = code;
      _errorRaw = raw ?? code;
    });
    _errorTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _errorCode = null);
    });
    inputFocus.requestFocus();
  }

  void _clearError() {
    if (_errorCode == null) return;
    _errorTimer?.cancel();
    setState(() => _errorCode = null);
  }

  Future<void> _addProduct(Product p, {int? embeddedPriceCents}) async {
    _clearError(); // the scanner beeps itself on a good scan
    if (p.unit == SaleUnit.kg) {
      int? grams;
      int lineTotal;
      if (embeddedPriceCents != null) {
        // Label from the scale: price is already calculated.
        lineTotal = embeddedPriceCents;
        grams = p.priceCents > 0
            ? (embeddedPriceCents * 1000 / p.priceCents).round()
            : null;
      } else {
        grams = await _askGrams(p);
        if (grams == null) return;
        lineTotal = (p.priceCents * grams / 1000).round();
      }
      setState(() => cart.add(
          CartLine(product: p, unitPriceCents: lineTotal, grams: grams)));
    } else {
      setState(() {
        final i = cart.indexWhere((l) =>
            l.product.plu == p.plu &&
            l.grams == null &&
            l.unitPriceCents == p.priceCents);
        if (i >= 0) {
          final line = cart.removeAt(i);
          line.quantity++;
          cart.add(line);
        } else {
          cart.add(CartLine(product: p, unitPriceCents: p.priceCents));
        }
      });
    }
    inputFocus.requestFocus();
  }

  /// Adds a product that is not in the PLU list. With "save" checked it is
  /// remembered (with its barcode, if given) for next time.
  Future<void> _addOwnProduct({String? ean}) async {
    _clearError();
    final name = TextEditingController();
    final price = TextEditingController();
    final code = TextEditingController(
        text: (ean != null && RegExp(r'^\d+$').hasMatch(ean)) ? ean : '');
    var save = code.text.isNotEmpty;
    final result = await showDialog<Product>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final cents = parseEuro(price.text);
        final valid = cents != null && cents > 0;
        Product build() => Product(
              plu: store.nextCustomPlu(),
              name: name.text.trim().isEmpty ? 'Diversen' : name.text.trim(),
              unit: SaleUnit.piece,
              priceCents: cents!,
              ean: code.text.replaceAll(RegExp(r'\D'), ''),
            );
        return AlertDialog(
          scrollable: true,
          title: const Text('Eigen product'),
          content: SizedBox(
            width: 380,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(
                    labelText: 'Naam', hintText: 'bijv. Diversen'),
              ),
              TextField(
                controller: price,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Prijs', prefixText: '€ '),
                onChanged: (_) => setD(() {}),
                onSubmitted: (_) {
                  if (valid) Navigator.pop(ctx, build());
                },
              ),
              const SizedBox(height: 8),
              NumPad(
                controller: price,
                decimal: true,
                keyHeight: 44,
                onChanged: () => setD(() {}),
              ),
              TextField(
                controller: code,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Barcode (optioneel, je kunt hier scannen)'),
                onChanged: (v) => setD(() {
                  if (v.trim().isNotEmpty) save = true;
                }),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: save,
                onChanged: (v) => setD(() => save = v ?? false),
                title: const Text('Bewaren in productlijst'),
                subtitle: const Text(
                    'Dan wordt hij de volgende keer herkend bij scannen'),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Annuleren')),
            FilledButton(
              onPressed: valid ? () => Navigator.pop(ctx, build()) : null,
              child: const Text('Toevoegen'),
            ),
          ],
        );
      }),
    );
    if (result == null) {
      inputFocus.requestFocus();
      return;
    }
    if (save) await store.addCustom(result);
    await _addProduct(result);
  }

  Future<int?> _askGrams(Product p) async {
    final c = TextEditingController();
    final grams = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p.displayName),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${euro(p.priceCents)} per kg'),
          const SizedBox(height: 12),
          TextField(
            controller: c,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Gewicht', suffixText: 'gram'),
            onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v.trim())),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 300,
            child: NumPad(
              controller: c,
              onEnter: () => Navigator.pop(ctx, int.tryParse(c.text.trim())),
              enterLabel: 'Toevoegen',
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuleren')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, int.tryParse(c.text.trim())),
              child: const Text('Toevoegen')),
        ],
      ),
    );
    return (grams != null && grams > 0) ? grams : null;
  }

  // ---------------------------------------------------------------- checkout

  Future<void> _checkout({required bool printBon}) async {
    if (cart.isEmpty) return;
    final lines = List<CartLine>.of(cart);
    final sum = total;
    final now = DateTime.now();
    final no = settings.nextReceiptNo;
    settings.nextReceiptNo++;
    await settings.save();
    await SalesLog.append(
        receiptNo: no, time: now, method: printBon ? 'bon' : 'geen bon', lines: lines);
    setState(() {
      cart.clear();
      todayTotal += sum;
    });
    if (printBon) {
      try {
        if (settings.printerIp.trim().isNotEmpty) {
          await sendToNetworkPrinter(
            settings.printerIp,
            buildEscPosReceipt(
                settings: settings,
                lines: lines,
                receiptNo: no,
                time: now,
                logo: await loadLogo()),
          );
        } else {
          final pdf = await buildReceipt(
              settings: settings, lines: lines, receiptNo: no, time: now);
          await printReceipt(pdf, settings);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Bon printen mislukt: $e'),
            backgroundColor: Colors.red.shade700,
          ));
        }
      }
    }
    inputFocus.requestFocus();
  }

  // ------------------------------------------------------- import & settings

  Future<void> _import() async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Kies PLU-bestand (CSV of Excel)',
      type: FileType.custom,
      allowedExtensions: ['csv', 'CSV', 'xlsx', 'txt'],
      withData: true,
    );
    if (picked == null) return;
    final f = picked.files.single;
    try {
      final bytes = f.bytes ?? await readPickedPath(f.path!);
      final r = importPluFile(bytes, f.name);
      if (r.products.isEmpty) {
        throw const FormatException('geen producten gevonden');
      }
      store.setProducts(r.products);
      await store.save();
      if (!mounted) return;
      setState(() {});
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('PLU ingelezen'),
          content: Text('${r.products.length} producten\n'
              '${r.withEan} met EAN-code\n'
              '${r.weighed} per kg (weegartikelen)\n'
              '${store.duplicateEans} dubbele EAN-codes '
              '(eerste product telt)\n'
              '${r.skippedRows} regels overgeslagen'),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Inlezen mislukt: $e')));
    }
  }

  Future<void> _editSettings() async {
    final name = TextEditingController(text: settings.shopName);
    final addr = TextEditingController(text: settings.address);
    final foot = TextEditingController(text: settings.footer);
    final ip = TextEditingController(text: settings.printerIp);
    final width =
        TextEditingController(text: settings.receiptWidth.toString());
    String testStatus = '';
    var hasLogo = await readBytes('logo.png') != null;
    if (!mounted) return;
    String? printerUrl = settings.printerUrl;
    String? printerName = settings.printerName;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          scrollable: true,
          title: const Text('Instellingen'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Winkelnaam')),
              TextField(
                  controller: addr,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: 'Adres / KvK / telefoon (op de bon)')),
              TextField(
                  controller: foot,
                  decoration:
                      const InputDecoration(labelText: 'Tekst onderaan bon')),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: ip,
                    decoration: const InputDecoration(
                        labelText: 'IP-adres bonprinter (Epson netwerk)',
                        hintText: 'bijv. 192.168.1.50'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: width,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Tekens/regel'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                OutlinedButton(
                  onPressed: () async {
                    final t = Settings(
                      shopName: name.text.trim(),
                      receiptWidth:
                          int.tryParse(width.text.trim()) ?? 33,
                    );
                    setD(() => testStatus = 'Bezig...');
                    try {
                      await sendToNetworkPrinter(ip.text,
                          buildEscPosTest(t, logo: await loadLogo()));
                      setD(() => testStatus = 'Testbon verstuurd');
                    } catch (e) {
                      setD(() => testStatus = 'Mislukt: $e');
                    }
                  },
                  child: const Text('Testbon'),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(testStatus)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: Text(hasLogo
                        ? 'Logo op de bon: ingesteld'
                        : 'Logo op de bon: standaard')),
                TextButton(
                  onPressed: () async {
                    final picked = await FilePicker.platform.pickFiles(
                      dialogTitle: 'Kies logo (PNG of JPG)',
                      type: FileType.image,
                      withData: true,
                    );
                    if (picked == null) return;
                    final f = picked.files.single;
                    final bytes =
                        f.bytes ?? await readPickedPath(f.path!);
                    final ok = await saveLogo(bytes);
                    setD(() {
                      hasLogo = ok || hasLogo;
                      testStatus = ok
                          ? 'Logo opgeslagen, maak een testbon'
                          : 'Dit bestand kan niet als logo gebruikt worden';
                    });
                  },
                  child: const Text('Kies logo'),
                ),
                if (hasLogo)
                  IconButton(
                    tooltip: 'Logo verwijderen',
                    icon: const Icon(Icons.clear),
                    onPressed: () async {
                      await removeLogo();
                      setD(() => hasLogo = false);
                    },
                  ),
              ]),
              if (!kIsWeb) ...[
                const SizedBox(height: 16),
              Row(children: [
                Expanded(
                    child: Text(
                        'Of Windows-printer: ${printerName ?? 'geen'}')),
                TextButton(
                  onPressed: () async {
                    final p = await Printing.pickPrinter(context: ctx);
                    if (p != null) {
                      setD(() {
                        printerUrl = p.url;
                        printerName = p.name;
                      });
                    }
                  },
                  child: const Text('Kies printer'),
                ),
                if (printerUrl != null)
                  IconButton(
                    tooltip: 'Wissen',
                    icon: const Icon(Icons.clear),
                    onPressed: () => setD(() {
                      printerUrl = null;
                      printerName = null;
                    }),
                  ),
              ]),
              ],
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Annuleren')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Opslaan')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    settings
      ..shopName = name.text.trim()
      ..address = addr.text
      ..footer = foot.text
      ..printerUrl = printerUrl
      ..printerName = printerName
      ..printerIp = ip.text.trim()
      ..receiptWidth = int.tryParse(width.text.trim()) ?? 33;
    await settings.save();
    inputFocus.requestFocus();
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Listener(
      onPointerDown: (_) => unlockSounds(),
      child: Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        title: Image.asset('assets/logo.png', height: 46),
        actions: [
          Center(child: Text('Vandaag: ${euro(todayTotal)}')),
          const SizedBox(width: 16),
          TextButton.icon(
            onPressed: _import,
            icon: const Icon(Icons.upload_file),
            label: Text('PLU inlezen (${store.products.length})'),
          ),
          IconButton(
            tooltip: 'Instellingen',
            onPressed: _editSettings,
            icon: const Icon(Icons.settings),
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: _showKeyboard
          ? OnScreenKeyboard(
              controller: input,
              onChanged: () => _onInputChanged(input.text),
              onEnter: () => _onSubmit(input.text),
              onClose: () => setState(() => _showKeyboard = false),
            )
          : null,
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Row(children: [
              Expanded(
                child: Stack(children: [
                  Positioned.fill(
                    child: Image.asset('assets/background.jpg',
                        fit: BoxFit.cover),
                  ),
                  Positioned.fill(child: _cartView(theme)),
                  if (_errorCode != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      top: 16,
                      child: GestureDetector(
                        onTap: _clearError,
                        child: Material(
                          elevation: 6,
                          borderRadius: BorderRadius.circular(12),
                          color: Colors.red.shade700,
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Row(children: [
                              const Icon(Icons.error_outline,
                                  color: Colors.white, size: 40),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('Niet herkend',
                                        style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold)),
                                    Text(
                                        'Code $_errorCode staat niet in de '
                                        'PLU-lijst. Scan opnieuw of zoek het '
                                        'product op.',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 16)),
                                  ],
                                ),
                              ),
                              if (RegExp(r'^\d+$')
                                  .hasMatch(_errorRaw ?? ''))
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: Colors.white,
                                      foregroundColor: Colors.red.shade700),
                                  onPressed: () =>
                                      _addOwnProduct(ean: _errorRaw),
                                  child: const Text('Toevoegen'),
                                ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                ]),
              ),
              const VerticalDivider(width: 1),
              ColoredBox(
                color: Colors.white,
                child: SizedBox(width: 380, child: _sidePanel(theme)),
              ),
            ]),
      ),
    );
  }

  Widget _cartView(ThemeData theme) {
    if (store.products.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Nog geen producten.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _import,
            icon: const Icon(Icons.upload_file),
            label: const Text('PLU-bestand inlezen'),
          ),
        ]),
      );
    }
    if (cart.isEmpty) {
      return Center(
        child: Container(
          padding: const EdgeInsets.fromLTRB(40, 32, 40, 28),
          decoration: BoxDecoration(
            color: const Color(0xCCFFFFFF),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Image.asset('assets/logo.png', width: 280),
            const SizedBox(height: 24),
            Text('Scan een product', style: theme.textTheme.headlineSmall),
          ]),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xE6FFFFFF),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: _cartList(theme),
    );
  }

  Widget _cartList(ThemeData theme) {
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: cart.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final l = cart[i];
        return ListTile(
          title: Text(l.product.displayName),
          subtitle: Text('PLU ${l.product.plu}  ·  ${lineDetail(l)}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              icon: const Icon(Icons.remove),
              onPressed: () => setState(() {
                if (l.quantity > 1) {
                  l.quantity--;
                } else {
                  cart.removeAt(i);
                }
              }),
            ),
            Text('${l.quantity}'),
            IconButton(
              icon: const Icon(Icons.add),
              onPressed: () => setState(() => l.quantity++),
            ),
            SizedBox(
              width: 90,
              child: Text(euro(l.totalCents),
                  textAlign: TextAlign.right,
                  style: theme.textTheme.titleMedium),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => setState(() => cart.removeAt(i)),
            ),
          ]),
        );
      },
    );
  }

  Widget _sidePanel(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: input,
          focusNode: inputFocus,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'PLU-nummer, EAN of zoeken',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              tooltip: 'Toetsenbord',
              icon: Icon(_showKeyboard
                  ? Icons.keyboard_hide
                  : Icons.keyboard_alt_outlined),
              onPressed: () =>
                  setState(() => _showKeyboard = !_showKeyboard),
            ),
          ),
          onChanged: _onInputChanged,
          onSubmitted: _onSubmit,
        ),
        Expanded(
          child: ListView(children: [
            for (final p in results)
              ListTile(
                dense: true,
                title: Text(p.displayName),
                subtitle: Text('PLU ${p.plu}'
                    '${p.ean.isNotEmpty ? '  ·  ${p.ean}' : ''}'),
                trailing: Text(p.unit == SaleUnit.kg
                    ? '${euro(p.priceCents)}/kg'
                    : euro(p.priceCents)),
                onTap: () {
                  _clearInput();
                  _addProduct(p);
                },
              ),
          ]),
        ),
        const Divider(),
        Row(children: [
          Text('Totaal', style: theme.textTheme.headlineSmall),
          const Spacer(),
          Text(euro(total), style: theme.textTheme.headlineMedium),
        ]),
        const SizedBox(height: 16),
        SizedBox(
          height: 64,
          child: FilledButton.icon(
            onPressed: cart.isEmpty ? null : () => _checkout(printBon: true),
            icon: const Icon(Icons.receipt_long),
            label: const Text('Bon', style: TextStyle(fontSize: 20)),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 64,
          child: FilledButton.tonalIcon(
            onPressed: cart.isEmpty ? null : () => _checkout(printBon: false),
            icon: const Icon(Icons.check),
            label: const Text('Geen bon', style: TextStyle(fontSize: 20)),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _addOwnProduct(),
          icon: const Icon(Icons.add),
          label: const Text('Eigen product / prijs'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: cart.isEmpty ? null : () => setState(cart.clear),
          child: const Text('Leegmaken'),
        ),
      ]),
    );
  }
}
