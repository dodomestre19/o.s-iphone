import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart' as xl;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signature/signature.dart';

// ---------------------------------------------------------------------------
// Peças mais comuns (botões de atalho no campo "Peças trocadas").
// Edite esta lista à vontade.
// ---------------------------------------------------------------------------
const kPecasComuns = [
  'Toner',
  'Cilindro',
  'Fusor',
  'Rolo de tração',
  'Rolo de pressão',
  'Unidade de imagem',
  'Correia de transferência',
];

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Atendimento OS',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const HomePage(),
      );
}

// ---------------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------------
String norm(String s) {
  const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
  const to = 'aaaaaeeeeiiiiooooouuuucn';
  var t = s.toLowerCase().trim();
  for (var i = 0; i < from.length; i++) {
    t = t.replaceAll(from[i], to[i]);
  }
  return t;
}

String two(int n) => n.toString().padLeft(2, '0');
String fmtData(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year}';
String fmtHora(DateTime d) => '${two(d.hour)}:${two(d.minute)}';
String fmtOs(int n) => n.toString().padLeft(5, '0');

void snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

// ---------------------------------------------------------------------------
// Modelos
// ---------------------------------------------------------------------------
class Registro {
  final String cliente, endereco, equipamento, serie;
  const Registro(this.cliente, this.endereco, this.equipamento, this.serie);

  Map<String, dynamic> toJson() =>
      {'c': cliente, 'e': endereco, 'q': equipamento, 's': serie};

  factory Registro.fromJson(Map<String, dynamic> j) => Registro(
        (j['c'] ?? '').toString(),
        (j['e'] ?? '').toString(),
        (j['q'] ?? '').toString(),
        (j['s'] ?? '').toString(),
      );
}

class Base {
  final List<Registro> registros;
  late final List<String> clientes;
  late final Map<String, String> _normDe; // nome original -> normalizado
  late final Map<String, List<Registro>> _porCliente;

  Base(this.registros) {
    _porCliente = {};
    _normDe = {};
    final nomes = <String, String>{};
    for (final r in registros) {
      final k = norm(r.cliente);
      (_porCliente[k] ??= []).add(r);
      nomes.putIfAbsent(k, () => r.cliente);
    }
    clientes = nomes.values.toList()
      ..sort((a, b) => norm(a).compareTo(norm(b)));
    for (final c in clientes) {
      _normDe[c] = norm(c);
    }
  }

  List<String> buscar(String q) {
    final n = norm(q);
    final it = n.isEmpty ? clientes : clientes.where((c) => _normDe[c]!.contains(n));
    return it.take(30).toList();
  }

  List<Registro> doCliente(String nome) =>
      _porCliente[norm(nome)] ?? const <Registro>[];
}

class Relatorio {
  final int os;
  final String cliente,
      endereco,
      pecas,
      equipamento,
      serie,
      pb,
      cor,
      tecnico,
      comentario,
      dataHora;
  String pdf;
  String sig; // assinatura (PNG em base64) - usada na versão web

  Relatorio({
    required this.os,
    required this.cliente,
    required this.endereco,
    required this.pecas,
    required this.equipamento,
    required this.serie,
    required this.pb,
    required this.cor,
    required this.tecnico,
    required this.comentario,
    required this.dataHora,
    this.pdf = '',
    this.sig = '',
  });

  Map<String, dynamic> toJson() => {
        'os': os,
        'cliente': cliente,
        'endereco': endereco,
        'pecas': pecas,
        'equipamento': equipamento,
        'serie': serie,
        'pb': pb,
        'cor': cor,
        'tecnico': tecnico,
        'comentario': comentario,
        'dataHora': dataHora,
        'pdf': pdf,
        if (sig.isNotEmpty) 'sig': sig,
      };

  factory Relatorio.fromJson(Map<String, dynamic> j) => Relatorio(
        os: (j['os'] as num?)?.toInt() ?? 0,
        cliente: (j['cliente'] ?? '').toString(),
        endereco: (j['endereco'] ?? '').toString(),
        pecas: (j['pecas'] ?? '').toString(),
        equipamento: (j['equipamento'] ?? '').toString(),
        serie: (j['serie'] ?? '').toString(),
        pb: (j['pb'] ?? '').toString(),
        cor: (j['cor'] ?? '').toString(),
        tecnico: (j['tecnico'] ?? '').toString(),
        comentario: (j['comentario'] ?? '').toString(),
        dataHora: (j['dataHora'] ?? '').toString(),
        pdf: (j['pdf'] ?? '').toString(),
        sig: (j['sig'] ?? '').toString(),
      );
}

// ---------------------------------------------------------------------------
// Armazenamento local (fica salvo mesmo fechando o app)
// ---------------------------------------------------------------------------
class Store {
  static Future<File> _arq(String nome) async =>
      File('${(await getApplicationDocumentsDirectory()).path}/$nome');

  /// Lê um texto salvo: arquivo no celular, armazenamento do navegador na web.
  static Future<String?> _lerTexto(String nome) async {
    if (kIsWeb) {
      return (await SharedPreferences.getInstance()).getString('arq_$nome');
    }
    final f = await _arq(nome);
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  static Future<void> _gravarTexto(String nome, String conteudo) async {
    if (kIsWeb) {
      await (await SharedPreferences.getInstance())
          .setString('arq_$nome', conteudo);
      return;
    }
    final f = await _arq(nome);
    await f.writeAsString(conteudo);
  }

  static Future<Directory> pdfDir() async {
    final d = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/relatorios');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<Base> loadBase() async {
    try {
      final txt = await _lerTexto('base.json');
      if (txt == null) return Base([]);
      final l = jsonDecode(txt) as List;
      return Base(l
          .map((e) => Registro.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList());
    } catch (_) {
      return Base([]);
    }
  }

  static Future<void> saveBase(Base b) async {
    await _gravarTexto(
        'base.json', jsonEncode(b.registros.map((r) => r.toJson()).toList()));
  }

  static Future<String> tecnico() async =>
      (await SharedPreferences.getInstance()).getString('tecnico') ?? '';

  static Future<void> setTecnico(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('tecnico', v.trim());
  }

  static Future<List<Relatorio>> loadHistorico() async {
    try {
      final txt = await _lerTexto('historico.json');
      if (txt == null) return [];
      final l = jsonDecode(txt) as List;
      return l
          .map((e) => Relatorio.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> adicionarHistorico(Relatorio r) async {
    final lista = await loadHistorico();
    lista.insert(0, r);
    await _gravarTexto(
        'historico.json', jsonEncode(lista.map((e) => e.toJson()).toList()));
  }

  static Future<String> empresa() async =>
      (await SharedPreferences.getInstance()).getString('empresa') ?? '';

  static Future<void> setEmpresa(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('empresa', v.trim());
  }

  /// Número que a próxima O.S. vai receber (só olha, não incrementa).
  static Future<int> previaOs() async =>
      ((await SharedPreferences.getInstance()).getInt('os') ?? 0) + 1;

  /// Reserva o número da O.S. (automático e crescente).
  static Future<int> gerarOs() async {
    final p = await SharedPreferences.getInstance();
    final n = (p.getInt('os') ?? 0) + 1;
    await p.setInt('os', n);
    return n;
  }

  static Future<void> definirProximaOs(int proxima) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('os', proxima - 1);
  }
}

// ---------------------------------------------------------------------------
// Leitura de planilhas (xlsx e csv)
// ---------------------------------------------------------------------------
String _cellStr(xl.Data? c) {
  final v = c?.value;
  if (v == null) return '';
  if (v is xl.IntCellValue) return v.value.toString();
  if (v is xl.DoubleCellValue) {
    final d = v.value;
    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
  }
  return v.toString();
}

List<List<String>> parseXlsx(Uint8List bytes) {
  final ex = xl.Excel.decodeBytes(bytes);
  for (final nome in ex.tables.keys) {
    final sheet = ex.tables[nome]!;
    if (sheet.maxRows > 0) {
      return sheet.rows.map((row) => row.map(_cellStr).toList()).toList();
    }
  }
  return [];
}

String _decodeTexto(Uint8List b) {
  try {
    return utf8.decode(b);
  } catch (_) {
    return latin1.decode(b); // CSV salvo pelo Excel costuma ser Windows-1252
  }
}

List<List<String>> parseCsv(Uint8List bytes) {
  var text = _decodeTexto(bytes);
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final primeira = text.split('\n').first;
  final sep =
      ';'.allMatches(primeira).length >= ','.allMatches(primeira).length ? ';' : ',';
  final rows = <List<String>>[];
  var row = <String>[];
  final cur = StringBuffer();
  var aspas = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (aspas) {
      if (ch == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cur.write('"');
          i++;
        } else {
          aspas = false;
        }
      } else {
        cur.write(ch);
      }
    } else if (ch == '"') {
      aspas = true;
    } else if (ch == sep) {
      row.add(cur.toString());
      cur.clear();
    } else if (ch == '\n') {
      row.add(cur.toString());
      cur.clear();
      rows.add(row);
      row = <String>[];
    } else if (ch != '\r') {
      cur.write(ch);
    }
  }
  if (cur.isNotEmpty || row.isNotEmpty) {
    row.add(cur.toString());
    rows.add(row);
  }
  return rows;
}

// ---------------------------------------------------------------------------
// Geração do PDF
// ---------------------------------------------------------------------------
Future<void> compartilharBytes(BuildContext context, Uint8List bytes,
    String nome, String mime, String texto) async {
  try {
    await Share.shareXFiles(
      [XFile.fromData(bytes, mimeType: mime, name: nome)],
      fileNameOverrides: [nome],
      text: texto,
    );
  } catch (e) {
    if (context.mounted) snack(context, 'Não foi possível compartilhar: $e');
  }
}

/// No celular compartilha direto. Na web (iPhone) o compartilhamento só abre
/// com um toque direto do usuário, então mostramos um aviso com o botão.
Future<void> entregarArquivo(BuildContext context, Uint8List bytes, String nome,
    String mime, String texto) async {
  if (!kIsWeb) {
    await compartilharBytes(context, bytes, nome, mime, texto);
    return;
  }
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Arquivo pronto'),
      content: Text(nome),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('Fechar')),
        FilledButton.icon(
          onPressed: () => compartilharBytes(ctx, bytes, nome, mime, texto),
          icon: const Icon(Icons.share),
          label: const Text('Compartilhar'),
        ),
      ],
    ),
  );
}

String slug(String s) {
  var t = norm(s);
  t = t.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  t = t.replaceAll(RegExp(r'_+'), '_');
  t = t.replaceAll(RegExp(r'^_|_$'), '');
  if (t.length > 40) t = t.substring(0, 40);
  return t.isEmpty ? 'cliente' : t;
}

class PdfGen {
  static String nomeArquivo(Relatorio r) =>
      'OS_${fmtOs(r.os)}_${slug(r.cliente)}.pdf';

  static Future<Uint8List> gerarBytes(
      Relatorio r, Uint8List assinatura, String empresa) async {
    final doc = pw.Document();
    final sig = pw.MemoryImage(assinatura);
    final headerBytes = await rootBundle.load('assets/header.png');
    final header = pw.MemoryImage(headerBytes.buffer
        .asUint8List(headerBytes.offsetInBytes, headerBytes.lengthInBytes));
    final dt = DateTime.parse(r.dataHora);

    pw.Widget campo(String rotulo, String valor) {
      return pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey400, width: 0.5)),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(rotulo,
                style: pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
            pw.SizedBox(height: 3),
            pw.Text(valor.trim().isEmpty ? '-' : valor,
                style: pw.TextStyle(fontSize: 12)),
          ],
        ),
      );
    }

    pw.Widget duas(pw.Widget a, pw.Widget b) => pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(child: a),
            pw.SizedBox(width: 8),
            pw.Expanded(child: b),
          ],
        );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (ctx) => [
          pw.Image(header, fit: pw.BoxFit.fitWidth),
          pw.SizedBox(height: 4),
          pw.Divider(color: PdfColors.grey400, thickness: 0.8),
          pw.SizedBox(height: 10),
          pw.Text('RELATÓRIO DE ATENDIMENTO',
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 4),
          pw.Text('O.S. Nº ${fmtOs(r.os)}',
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 14),
          duas(campo('DATA', fmtData(dt)), campo('HORA', fmtHora(dt))),
          pw.SizedBox(height: 6),
          campo('CLIENTE', r.cliente),
          pw.SizedBox(height: 6),
          campo('ENDEREÇO', r.endereco),
          pw.SizedBox(height: 6),
          duas(campo('EQUIPAMENTO REVISADO', r.equipamento),
              campo('NÚMERO DE SÉRIE', r.serie)),
          pw.SizedBox(height: 6),
          duas(campo('CONTADOR P/B', r.pb), campo('CONTADOR COLORIDO', r.cor)),
          pw.SizedBox(height: 6),
          campo('TÉCNICO', r.tecnico),
          pw.SizedBox(height: 6),
          campo('PEÇAS TROCADAS', r.pecas),
          pw.SizedBox(height: 6),
          campo('COMENTÁRIO', r.comentario),
          pw.SizedBox(height: 20),
          pw.Text('ASSINATURA DO CLIENTE',
              style: pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
          pw.SizedBox(height: 4),
          pw.Container(
            height: 100,
            width: double.infinity,
            padding: const pw.EdgeInsets.all(4),
            decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey400, width: 0.5)),
            child: pw.Image(sig, fit: pw.BoxFit.contain),
          ),
          pw.SizedBox(height: 4),
          pw.Text(r.cliente, style: pw.TextStyle(fontSize: 10)),
        ],
      ),
    );

    return await doc.save();
  }
}

// ---------------------------------------------------------------------------
// Tela inicial
// ---------------------------------------------------------------------------
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Base _base = Base([]);
  int _qtdHist = 0;
  bool _carregando = true;

  @override
  void initState() {
    super.initState();
    _carregar();
  }

  Future<void> _carregar() async {
    final b = await Store.loadBase();
    final h = await Store.loadHistorico();
    if (!mounted) return;
    setState(() {
      _base = b;
      _qtdHist = h.length;
      _carregando = false;
    });
  }

  Future<void> _importar() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'csv'],
      withData: true,
    );
    if (res == null || res.files.isEmpty) return;
    final file = res.files.first;

    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes == null) {
      if (mounted) snack(context, 'Não consegui ler o arquivo.');
      return;
    }

    List<List<String>> linhas;
    try {
      linhas = (file.extension ?? '').toLowerCase() == 'csv'
          ? parseCsv(bytes)
          : parseXlsx(bytes);
    } catch (e) {
      if (mounted) {
        snack(context,
            'Erro ao ler a planilha. Tente abrir no Excel e salvar de novo como .xlsx (ou CSV).');
      }
      return;
    }
    while (linhas.isNotEmpty && linhas.first.every((c) => c.trim().isEmpty)) {
      linhas.removeAt(0);
    }
    if (linhas.length < 2) {
      if (mounted) snack(context, 'A planilha está vazia.');
      return;
    }
    if (!mounted) return;

    final m = await showDialog<List<int>>(
      context: context,
      builder: (_) => MapeamentoDialog(cabecalho: linhas.first),
    );
    if (m == null) return;

    String cell(List<String> r, int i) =>
        (i >= 0 && i < r.length) ? r[i].trim() : '';

    final regs = <Registro>[];
    var ultCli = '', ultEnd = '';
    for (final r in linhas.skip(1)) {
      var cli = cell(r, m[0]);
      var end = cell(r, m[1]);
      final eq = cell(r, m[2]);
      final se = cell(r, m[3]);
      if (cli.isEmpty) {
        if (eq.isEmpty && se.isEmpty) continue;
        cli = ultCli; // células mescladas / cliente em branco
      }
      if (cli.isEmpty) continue;
      if (end.isEmpty && cli == ultCli) end = ultEnd;
      ultCli = cli;
      ultEnd = end;
      regs.add(Registro(cli, end, eq, se));
    }

    if (regs.isEmpty) {
      if (mounted) snack(context, 'Nenhum cliente encontrado na coluna escolhida.');
      return;
    }

    final nova = Base(regs);
    await Store.saveBase(nova);
    if (!mounted) return;
    setState(() => _base = nova);
    snack(context,
        'Importado: ${nova.clientes.length} clientes, ${regs.length} equipamentos.');
  }

  Future<void> _adicionarCliente() async {
    final novo = await showDialog<Registro>(
      context: context,
      builder: (_) => const ClienteDialog(),
    );
    if (novo == null) return;
    final nova = Base([..._base.registros, novo]);
    await Store.saveBase(nova);
    if (!mounted) return;
    setState(() => _base = nova);
    snack(context, 'Cliente cadastrado.');
  }

  Future<void> _novo() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => FormPage(base: _base)));
    _carregar();
  }

  Future<void> _historico() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const HistoricoPage()));
    _carregar();
  }

  Future<void> _config() async {
    await showDialog(context: context, builder: (_) => const ConfigDialog());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Atendimento OS'),
        actions: [
          IconButton(
              icon: const Icon(Icons.settings),
              tooltip: 'Configurações',
              onPressed: _config),
        ],
      ),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Base de clientes',
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text(_base.registros.isEmpty
                            ? 'Nenhuma planilha importada ainda.'
                            : '${_base.clientes.length} clientes  -  ${_base.registros.length} equipamentos'),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _importar,
                              icon: const Icon(Icons.upload_file),
                              label: Text(_base.registros.isEmpty
                                  ? 'Importar planilha (Excel/CSV)'
                                  : 'Atualizar planilha'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _adicionarCliente,
                              icon: const Icon(Icons.person_add_alt_1),
                              label: const Text('Adicionar cliente'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(64)),
                  onPressed: _novo,
                  icon: const Icon(Icons.assignment),
                  label: const Text('Novo atendimento',
                      style: TextStyle(fontSize: 18)),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52)),
                  onPressed: _historico,
                  icon: const Icon(Icons.history),
                  label: Text('Histórico ($_qtdHist)'),
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Escolha das colunas da planilha
// ---------------------------------------------------------------------------
class MapeamentoDialog extends StatefulWidget {
  final List<String> cabecalho;
  const MapeamentoDialog({super.key, required this.cabecalho});

  @override
  State<MapeamentoDialog> createState() => _MapeamentoDialogState();
}

class _MapeamentoDialogState extends State<MapeamentoDialog> {
  late List<int> _m;

  int _adivinhar(List<String> h, List<String> chaves) {
    for (var i = 0; i < h.length; i++) {
      final n = norm(h[i]);
      if (chaves.any((k) => n.contains(k))) return i;
    }
    return -1;
  }

  @override
  void initState() {
    super.initState();
    final h = widget.cabecalho;
    _m = [
      _adivinhar(h, ['cliente', 'nome', 'razao', 'empresa']),
      _adivinhar(h, ['endere', 'logradouro']),
      _adivinhar(h, ['equip', 'modelo', 'maquina', 'impressora']),
      _adivinhar(h, ['serie', 'serial', 's/n']),
    ];
  }

  String _nomeCol(int i) {
    final t = widget.cabecalho[i].trim();
    return t.isEmpty ? 'Coluna ${i + 1}' : t;
  }

  Widget _drop(String rotulo, int i) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<int>(
        isExpanded: true,
        value: _m[i],
        decoration:
            InputDecoration(labelText: rotulo, border: const OutlineInputBorder()),
        items: <DropdownMenuItem<int>>[
          const DropdownMenuItem<int>(value: -1, child: Text('(nenhuma)')),
          for (var c = 0; c < widget.cabecalho.length; c++)
            DropdownMenuItem<int>(
              value: c,
              child: Text(_nomeCol(c), overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (v) => setState(() => _m[i] = v ?? -1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Quais colunas usar?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Confira qual coluna da planilha corresponde a cada campo.'),
            ),
            _drop('Nome do cliente', 0),
            _drop('Endereço', 1),
            _drop('Equipamento', 2),
            _drop('Número de série', 3),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: _m[0] < 0 ? null : () => Navigator.pop(context, _m),
          child: const Text('Importar'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Configurações
// ---------------------------------------------------------------------------
class ConfigDialog extends StatefulWidget {
  const ConfigDialog({super.key});

  @override
  State<ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<ConfigDialog> {
  final _empresa = TextEditingController();
  final _os = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final e = await Store.empresa();
    final o = await Store.previaOs();
    if (!mounted) return;
    setState(() {
      _empresa.text = e;
      _os.text = '$o';
    });
  }

  @override
  void dispose() {
    _empresa.dispose();
    _os.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Configurações'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _empresa,
              decoration: const InputDecoration(
                  labelText: 'Nome da empresa (cabeçalho do PDF)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _os,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                  labelText: 'Próximo nº da O.S.', border: OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () async {
            await Store.setEmpresa(_empresa.text);
            final n = int.tryParse(_os.text.trim());
            if (n != null && n > 0) await Store.definirProximaOs(n);
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Salvar'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Cadastro de cliente novo
// ---------------------------------------------------------------------------
class ClienteDialog extends StatefulWidget {
  final String nomeInicial;
  const ClienteDialog({super.key, this.nomeInicial = ''});

  @override
  State<ClienteDialog> createState() => _ClienteDialogState();
}

class _ClienteDialogState extends State<ClienteDialog> {
  final _form = GlobalKey<FormState>();
  late final _nome = TextEditingController(text: widget.nomeInicial);
  final _endereco = TextEditingController();
  final _equip = TextEditingController();
  final _serie = TextEditingController();

  @override
  void dispose() {
    for (final c in [_nome, _endereco, _equip, _serie]) {
      c.dispose();
    }
    super.dispose();
  }

  void _salvar() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(
      context,
      Registro(_nome.text.trim(), _endereco.text.trim(), _equip.text.trim(),
          _serie.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cadastrar cliente'),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nome,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Nome do cliente', border: OutlineInputBorder()),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Informe o nome' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _endereco,
                maxLines: 2,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Endereço', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _equip,
                decoration: const InputDecoration(
                    labelText: 'Equipamento (opcional)',
                    border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _serie,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                    labelText: 'Número de série (opcional)',
                    border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
        FilledButton(onPressed: _salvar, child: const Text('Cadastrar')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Novo atendimento
// ---------------------------------------------------------------------------
class FormPage extends StatefulWidget {
  final Base base;
  const FormPage({super.key, required this.base});

  @override
  State<FormPage> createState() => _FormPageState();
}

class _FormPageState extends State<FormPage> {
  final _form = GlobalKey<FormState>();
  final _cliente = TextEditingController();
  final _clienteFocus = FocusNode();
  final _endereco = TextEditingController();
  final _equip = TextEditingController();
  final _serie = TextEditingController();
  final _pb = TextEditingController();
  final _cor = TextEditingController();
  final _pecas = TextEditingController();
  final _tecnico = TextEditingController();
  final _coment = TextEditingController();

  late Base _base;
  Uint8List? _assinatura;
  DateTime _agora = DateTime.now();
  Timer? _timer;
  int _proximaOs = 0;
  String? _selKey;
  int? _selIdx;
  bool _salvando = false;

  @override
  void initState() {
    super.initState();
    _base = widget.base;
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() => _agora = DateTime.now());
    });
    _cliente.addListener(() {
      if (mounted) setState(() {});
    });
    Store.previaOs().then((n) {
      if (mounted) setState(() => _proximaOs = n);
    });
    Store.tecnico().then((t) {
      if (mounted && t.isNotEmpty) setState(() => _tecnico.text = t);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c
        in [_cliente, _endereco, _equip, _serie, _pb, _cor, _pecas, _tecnico, _coment]) {
      c.dispose();
    }
    _clienteFocus.dispose();
    super.dispose();
  }

  void _aplicar(Registro r, int idx, String nome) {
    _endereco.text = r.endereco;
    _equip.text = r.equipamento;
    _serie.text = r.serie;
    setState(() {
      _selKey = norm(nome);
      _selIdx = idx;
    });
  }

  void _selecionarCliente(String nome) {
    final regs = _base.doCliente(nome);
    if (regs.isEmpty) return;
    if (regs.length == 1) {
      _aplicar(regs.first, 0, nome);
    } else {
      _endereco.text = regs.first.endereco;
      _equip.clear();
      _serie.clear();
      setState(() {
        _selKey = null;
        _selIdx = null;
      });
    }
  }

  void _addPeca(String p) {
    final t = _pecas.text.trim();
    _pecas.text = t.isEmpty ? p : '$t, $p';
    _pecas.selection = TextSelection.collapsed(offset: _pecas.text.length);
  }

  Future<void> _cadastrarCliente() async {
    final novo = await showDialog<Registro>(
      context: context,
      builder: (_) => ClienteDialog(nomeInicial: _cliente.text.trim()),
    );
    if (novo == null || !mounted) return;
    final regs = [..._base.registros, novo];
    final nova = Base(regs);
    await Store.saveBase(nova);
    if (!mounted) return;
    setState(() {
      _base = nova;
      _cliente.text = novo.cliente;
      _endereco.text = novo.endereco;
      _equip.text = novo.equipamento;
      _serie.text = novo.serie;
      _selKey = norm(novo.cliente);
      _selIdx = nova.doCliente(novo.cliente).length - 1;
    });
    snack(context, 'Cliente cadastrado.');
  }

  Future<void> _assinar() async {
    final r = await Navigator.push<Uint8List>(
        context, MaterialPageRoute(builder: (_) => const AssinaturaPage()));
    if (r != null && mounted) setState(() => _assinatura = r);
  }

  Future<void> _salvar() async {
    if (!_form.currentState!.validate()) return;
    if (_assinatura == null) {
      snack(context, 'Colete a assinatura do cliente antes de salvar.');
      return;
    }
    setState(() => _salvando = true);
    try {
      final os = await Store.gerarOs();
      final rel = Relatorio(
        os: os,
        cliente: _cliente.text.trim(),
        endereco: _endereco.text.trim(),
        pecas: _pecas.text.trim(),
        equipamento: _equip.text.trim(),
        serie: _serie.text.trim(),
        pb: _pb.text.trim(),
        cor: _cor.text.trim(),
        tecnico: _tecnico.text.trim(),
        comentario: _coment.text.trim(),
        dataHora: DateTime.now().toIso8601String(),
      );
      await Store.setTecnico(_tecnico.text);
      final empresa = await Store.empresa();
      final pdfBytes = await PdfGen.gerarBytes(rel, _assinatura!, empresa);
      final pdfNome = PdfGen.nomeArquivo(rel);
      if (kIsWeb) {
        rel.sig = base64Encode(_assinatura!);
      } else {
        final dir = await Store.pdfDir();
        await File('${dir.path}/$pdfNome').writeAsBytes(pdfBytes);
      }
      rel.pdf = pdfNome;
      await Store.adicionarHistorico(rel);
      if (!mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text('O.S. ${fmtOs(os)} salva'),
          content: const Text('O relatório em PDF foi gerado e guardado no histórico.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('Fechar')),
            FilledButton.icon(
              onPressed: () => compartilharBytes(ctx, pdfBytes, pdfNome,
                  'application/pdf',
                  'Relatório de atendimento - O.S. ${fmtOs(os)}'),
              icon: const Icon(Icons.share),
              label: const Text('Compartilhar PDF'),
            ),
          ],
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _salvando = false);
        snack(context, 'Erro ao salvar: $e');
      }
    }
  }

  InputDecoration _dec(String rotulo, {String? dica}) => InputDecoration(
      labelText: rotulo, hintText: dica, border: const OutlineInputBorder());

  Widget _leitura(String rotulo, String valor) => InputDecorator(
        decoration: InputDecoration(
          labelText: rotulo,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.lock_clock, size: 18),
        ),
        child: Text(valor, style: const TextStyle(fontSize: 16)),
      );

  @override
  Widget build(BuildContext context) {
    final opcoes = _base.doCliente(_cliente.text);
    final idx = (opcoes.isNotEmpty &&
            _selKey == norm(_cliente.text) &&
            _selIdx != null &&
            _selIdx! < opcoes.length)
        ? _selIdx
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Novo atendimento')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(16),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            Text(
              'O.S. Nº ${fmtOs(_proximaOs)} (automática)',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _leitura('Data', fmtData(_agora))),
                const SizedBox(width: 12),
                Expanded(child: _leitura('Hora', fmtHora(_agora))),
              ],
            ),
            const SizedBox(height: 16),

            // Cliente com busca na base importada
            RawAutocomplete<String>(
              textEditingController: _cliente,
              focusNode: _clienteFocus,
              optionsBuilder: (v) => _base.buscar(v.text),
              onSelected: _selecionarCliente,
              fieldViewBuilder: (ctx, ctl, focus, onSubmit) => TextFormField(
                controller: ctl,
                focusNode: focus,
                textCapitalization: TextCapitalization.words,
                decoration: _dec('Nome do cliente',
                    dica: _base.registros.isEmpty
                        ? 'Digite o nome'
                        : 'Digite para buscar na planilha'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Informe o cliente' : null,
              ),
              optionsViewBuilder: (ctx, onSel, options) => Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: 240,
                      maxWidth: MediaQuery.of(ctx).size.width - 32,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: options.length,
                      itemBuilder: (_, i) {
                        final o = options.elementAt(i);
                        return ListTile(
                            dense: true, title: Text(o), onTap: () => onSel(o));
                      },
                    ),
                  ),
                ),
              ),
            ),
            if (_cliente.text.trim().isNotEmpty && opcoes.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _cadastrarCliente,
                    icon: const Icon(Icons.person_add_alt_1, size: 18),
                    label: Text('Cadastrar "${_cliente.text.trim()}" como cliente novo'),
                  ),
                ),
              ),
            const SizedBox(height: 12),

            // Equipamentos daquele cliente (vindos da planilha)
            if (opcoes.isNotEmpty) ...[
              DropdownButtonFormField<int>(
                isExpanded: true,
                value: idx,
                decoration: _dec('Equipamento do cliente (selecione)'),
                items: [
                  for (var i = 0; i < opcoes.length; i++)
                    DropdownMenuItem<int>(
                      value: i,
                      child: Text(
                        '${opcoes[i].equipamento.isEmpty ? "(sem nome)" : opcoes[i].equipamento}  -  Nº ${opcoes[i].serie.isEmpty ? "-" : opcoes[i].serie}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (i) {
                  if (i == null) return;
                  _aplicar(opcoes[i], i, _cliente.text);
                },
              ),
              const SizedBox(height: 12),
            ],

            TextFormField(
              controller: _endereco,
              maxLines: 2,
              textCapitalization: TextCapitalization.words,
              decoration: _dec('Endereço'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _equip,
              decoration: _dec('Equipamento revisado'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _serie,
              textCapitalization: TextCapitalization.characters,
              decoration: _dec('Número de série'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _pb,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: _dec('Contador P/B'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _cor,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: _dec('Contador colorido'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _tecnico,
              textCapitalization: TextCapitalization.words,
              decoration: _dec('Técnico'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Informe o técnico' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _pecas,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: _dec('Peças trocadas', dica: 'Toque nos atalhos abaixo ou digite'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final p in kPecasComuns)
                  ActionChip(label: Text(p), onPressed: () => _addPeca(p)),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _coment,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: _dec('Comentário'),
            ),
            const SizedBox(height: 16),

            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    if (_assinatura != null)
                      Container(
                        height: 120,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.grey.shade400),
                        ),
                        child: Image.memory(_assinatura!, fit: BoxFit.contain),
                      )
                    else
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('Assinatura do cliente ainda não coletada.'),
                      ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _assinar,
                      icon: const Icon(Icons.draw),
                      label: Text(_assinatura == null
                          ? 'Coletar assinatura do cliente'
                          : 'Refazer assinatura'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: _salvando ? null : _salvar,
              icon: _salvando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.picture_as_pdf),
              label: const Text('Salvar e gerar PDF', style: TextStyle(fontSize: 16)),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tela de assinatura (tela cheia)
// ---------------------------------------------------------------------------
class AssinaturaPage extends StatefulWidget {
  const AssinaturaPage({super.key});

  @override
  State<AssinaturaPage> createState() => _AssinaturaPageState();
}

class _AssinaturaPageState extends State<AssinaturaPage> {
  final _c = SignatureController(
    penStrokeWidth: 3,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _confirmar() async {
    if (_c.isEmpty) {
      snack(context, 'O cliente ainda não assinou.');
      return;
    }
    final bytes = await _c.toPngBytes();
    if (!mounted) return;
    Navigator.pop(context, bytes);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Assinatura do cliente'),
        actions: [
          TextButton(onPressed: () => _c.clear(), child: const Text('Limpar')),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Peça ao cliente para assinar com o dedo no quadro abaixo.'),
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade600, width: 1.5),
                ),
                child: Signature(controller: _c, backgroundColor: Colors.white),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: _confirmar,
                      child: const Text('Confirmar'),
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

// ---------------------------------------------------------------------------
// Histórico
// ---------------------------------------------------------------------------
class HistoricoPage extends StatefulWidget {
  const HistoricoPage({super.key});

  @override
  State<HistoricoPage> createState() => _HistoricoPageState();
}

class _HistoricoPageState extends State<HistoricoPage> {
  List<Relatorio> _lista = [];
  bool _carregando = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await Store.loadHistorico();
    if (!mounted) return;
    setState(() {
      _lista = l;
      _carregando = false;
    });
  }

  Future<void> _compartilhar(Relatorio r) async {
    Uint8List bytes;
    if (kIsWeb) {
      if (r.sig.isEmpty) {
        if (mounted) snack(context, 'PDF não disponível para este atendimento.');
        return;
      }
      try {
        final empresa = await Store.empresa();
        bytes = await PdfGen.gerarBytes(r, base64Decode(r.sig), empresa);
      } catch (e) {
        if (mounted) snack(context, 'Erro ao gerar o PDF: $e');
        return;
      }
    } else {
      final f = File('${(await Store.pdfDir()).path}/${r.pdf}');
      if (!await f.exists()) {
        if (mounted) snack(context, 'PDF não encontrado.');
        return;
      }
      bytes = await f.readAsBytes();
    }
    if (!mounted) return;
    await entregarArquivo(
        context,
        bytes,
        r.pdf.isEmpty ? PdfGen.nomeArquivo(r) : r.pdf,
        'application/pdf',
        'Relatório de atendimento - O.S. ${fmtOs(r.os)}');
  }

  xl.CellValue _num(String s) {
    final n = int.tryParse(s.trim());
    return n != null ? xl.IntCellValue(n) : xl.TextCellValue(s);
  }

  Future<void> _exportar() async {
    try {
      final ex = xl.Excel.createExcel();
      final sh = ex['Sheet1'];
      sh.appendRow([
        xl.TextCellValue('O.S.'),
        xl.TextCellValue('Data'),
        xl.TextCellValue('Hora'),
        xl.TextCellValue('Cliente'),
        xl.TextCellValue('Endereço'),
        xl.TextCellValue('Equipamento'),
        xl.TextCellValue('Nº de série'),
        xl.TextCellValue('Contador P/B'),
        xl.TextCellValue('Contador colorido'),
        xl.TextCellValue('Técnico'),
        xl.TextCellValue('Peças trocadas'),
        xl.TextCellValue('Comentário'),
      ]);
      for (final r in _lista.reversed) {
        final dt = DateTime.tryParse(r.dataHora) ?? DateTime.now();
        sh.appendRow([
          xl.IntCellValue(r.os),
          xl.TextCellValue(fmtData(dt)),
          xl.TextCellValue(fmtHora(dt)),
          xl.TextCellValue(r.cliente),
          xl.TextCellValue(r.endereco),
          xl.TextCellValue(r.equipamento),
          xl.TextCellValue(r.serie),
          _num(r.pb),
          _num(r.cor),
          xl.TextCellValue(r.tecnico),
          xl.TextCellValue(r.pecas),
          xl.TextCellValue(r.comentario),
        ]);
      }
      // Na web usamos encode() (save() tentaria baixar o arquivo sozinho).
      final bytes = kIsWeb ? ex.encode() : ex.save();
      if (bytes == null) return;
      if (!mounted) return;
      await entregarArquivo(
          context,
          Uint8List.fromList(bytes),
          'atendimentos.xlsx',
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          'Atendimentos');
    } catch (e) {
      if (mounted) snack(context, 'Erro ao exportar: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Histórico'),
        actions: [
          IconButton(
            icon: const Icon(Icons.table_view),
            tooltip: 'Exportar para Excel',
            onPressed: _lista.isEmpty ? null : _exportar,
          ),
        ],
      ),
      body: _carregando
          ? const Center(child: CircularProgressIndicator())
          : _lista.isEmpty
              ? const Center(child: Text('Nenhum atendimento salvo ainda.'))
              : ListView.separated(
                  itemCount: _lista.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = _lista[i];
                    final dt = DateTime.tryParse(r.dataHora);
                    return ListTile(
                      title: Text('O.S. ${fmtOs(r.os)}  -  ${r.cliente}'),
                      subtitle: Text([
                        if (dt != null) '${fmtData(dt)} ${fmtHora(dt)}',
                        if (r.equipamento.isNotEmpty) r.equipamento,
                        if (r.serie.isNotEmpty) 'Nº ${r.serie}',
                        if (r.tecnico.isNotEmpty) 'Téc. ${r.tecnico}',
                      ].join('  -  ')),
                      trailing: const Icon(Icons.share),
                      onTap: () => _compartilhar(r),
                    );
                  },
                ),
    );
  }
}
