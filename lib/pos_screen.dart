import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:printing/printing.dart';

import 'barcode_listener.dart';
import 'escpos.dart';
import 'models.dart';
import 'plu_import.dart';
import 'product_store.dart';
import 'receipt.dart';
import 'settings.dart';

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
    final r = resolveScan(code, store);
    if (r == null) {
      _notFound(code);
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

  void _notFound(String code) {
    SystemSound.play(SystemSoundType.alert);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Onbekende code: $code'),
      backgroundColor: Colors.red.shade700,
    ));
  }

  Future<void> _addProduct(Product p, {int? embeddedPriceCents}) async {
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
                settings: settings, lines: lines, receiptNo: no, time: now),
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
      final bytes = f.bytes ?? await File(f.path!).readAsBytes();
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
                      await sendToNetworkPrinter(
                          ip.text, buildEscPosTest(t));
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
    return Scaffold(
      appBar: AppBar(
        title: Text(settings.shopName),
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
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Row(children: [
              Expanded(child: _cartView(theme)),
              const VerticalDivider(width: 1),
              SizedBox(width: 380, child: _sidePanel(theme)),
            ]),
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
        child: Text('Scan een product',
            style: theme.textTheme.headlineSmall
                ?.copyWith(color: theme.colorScheme.outline)),
      );
    }
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
          decoration: const InputDecoration(
            labelText: 'PLU-nummer, EAN of zoeken',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.search),
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
        OutlinedButton(
          onPressed: cart.isEmpty ? null : () => setState(cart.clear),
          child: const Text('Leegmaken'),
        ),
      ]),
    );
  }
}
