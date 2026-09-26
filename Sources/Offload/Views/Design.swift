import AppKit
import SwiftUI

// MARK: - Тема

/// Общий язык интерфейса: отступы, скругления и цвета.
///
/// Стиль — белое стекло, как у Dock и строки меню: фон окна — размытый рабочий стол под белой дымкой,
/// карточки — полупрозрачные белые пластины со светлой кромкой и мягкой тенью.
///
/// Цвет здесь сообщает, а не украшает: зелёный — зашифровано и готово, оранжевый — лежит
/// открыто или требует внимания, красный — ошибка, серый — трогать нельзя или делать нечего.
/// Бирюзовый из иконки — только для действий и шкал, чтобы он не спорил с цветами состояний.
enum Theme {
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 16
    /// Шире колонка страницы не растягивается: на большом мониторе строки иначе читались бы с трудом.
    static let contentWidth: CGFloat = 980

    /// В тёмной теме чуть светлее, чтобы шкалы и кнопки не тонули в фоне;
    /// белый текст на кнопке остаётся читаемым в обеих темах.
    static let brand = dynamic(light: NSColor(srgbRed: 0.05, green: 0.52, blue: 0.48, alpha: 1),
                               dark: NSColor(srgbRed: 0.06, green: 0.60, blue: 0.55, alpha: 1))
    /// Стекло карточки: белое и полупрозрачное в светлой теме, едва светлее фона — в тёмной.
    static let cardFill = dynamic(light: NSColor(white: 1, alpha: 0.74), dark: NSColor(white: 1, alpha: 0.07))
    static let cardStroke = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.09))
    /// Кромка стекла: светлый блик сверху, едва заметная граница снизу.
    static let glassEdgeTop = dynamic(light: NSColor(white: 1, alpha: 0.95), dark: NSColor(white: 1, alpha: 0.2))
    static let glassEdgeBottom = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.05))
    /// Тень под стеклом: мягкая, чтобы карточка висела над фоном, а не лежала на нём.
    static let glassShadow = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 0, alpha: 0.35))
    /// Белая дымка поверх размытого рабочего стола: страница светлая при любых обоях, текст на ней читается.
    static let pageWash = dynamic(light: NSColor(white: 1, alpha: 0.42), dark: NSColor(white: 0, alpha: 0.12))
    /// Дорожка шкал и колец.
    static let track = dynamic(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.12))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// Что сообщает цвет. Один набор на всё приложение, чтобы оранжевое везде значило одно и то же.
enum Tone {
    case good, caution, danger, neutral, brand, info

    var color: Color {
        switch self {
        case .good: return .green
        case .caution: return .orange
        case .danger: return .red
        case .neutral: return .secondary
        case .brand: return Theme.brand
        case .info: return .blue
        }
    }
}

// MARK: - Стекло

/// Фон окна, как у Dock: рабочий стол просвечивает сквозь размытие. Размытие не гаснет,
/// когда окно не в фокусе, — стекло остаётся стеклом.
struct WindowGlass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Подложка из белого стекла: полупрозрачная пластина, светлая кромка сверху и мягкая тень.
/// Тень — только у подложки: текст поверх неё не размывается.
struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    /// Подкрашенное стекло — для предупреждений, которые не должны теряться среди прочих.
    var tint: Color?

    var body: some View {
        shape.fill(Theme.cardFill)
            .overlay {
                if let tint {
                    shape.fill(tint.opacity(0.08))
                    shape.strokeBorder(tint.opacity(0.28))
                } else {
                    shape.strokeBorder(LinearGradient(colors: [Theme.glassEdgeTop, Theme.glassEdgeBottom],
                                                      startPoint: .top, endPoint: .bottom))
                }
            }
            .shadow(color: Theme.glassShadow, radius: 14, y: 5)
    }
}

extension View {
    /// Белое стекло под представлением.
    func glass<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        background { GlassSurface(shape: shape, tint: tint) }
    }
}

// MARK: - Страница и карточки

/// Страница-колонка: прокрутка, поля и предельная ширина, по центру окна.
struct PageScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                content
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: Theme.contentWidth)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Карточка — основной строительный блок страниц. Содержимое собирается в колонку:
/// модификаторы, навешенные на несколько представлений сразу, разошлись бы по каждому.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.cardPadding
    var spacing: CGFloat = 12
    /// Растянуться на высоту соседей в ряду (вместе с `fixedSize` у ряда).
    var fillsHeight = false
    /// Подкрашенная карточка — для предупреждений, которые не должны теряться среди прочих.
    var tint: Color?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .glass(in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous), tint: tint)
    }
}

/// Заголовок внутри карточки: значок, название и что-нибудь справа.
struct CardTitle<Accessory: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title).font(.headline)
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension CardTitle where Accessory == EmptyView {
    init(_ title: String, systemImage: String) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}

/// Раздел страницы: заголовок над карточкой, как в Системных настройках, и пояснение под ней.
/// Строки внутри отбиваются `RowDivider` и сами задают себе поля (`rowPadding`).
struct CardSection<Content: View>: View {
    let title: String
    /// Номер шага, если раздел — часть последовательности.
    var number: Int?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let number {
                    Text("\(number)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Theme.brand, in: Circle())
                }
                Text(title).font(.headline)
            }
            .padding(.horizontal, 4)
            Card(padding: 0, spacing: 0) {
                content
            }
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

extension View {
    /// Поля строки внутри карточки-списка.
    func rowPadding() -> some View {
        padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// Разделитель строк карточки-списка: начинается там же, где текст строк.
struct RowDivider: View {
    var inset: CGFloat = 14

    var body: some View {
        Divider().padding(.leading, inset)
    }
}

/// Строка карточки-списка: название с пояснением слева, управление справа.
struct FormRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .rowPadding()
    }
}

/// Переключатель во всю строку: подпись слева, переключатель справа.
struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        FormRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// Название и значение в одну строку, значение прижато вправо. Шрифт задаёт тот, кто вставляет строку.
struct InfoRow<Value: View>: View {
    let title: String
    @ViewBuilder let value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            value
        }
    }
}

extension InfoRow where Value == Text {
    init(_ title: String, value: String) {
        self.init(title: title) { Text(value) }
    }
}

// MARK: - Значки и плашки

/// Символ на скруглённой подложке своего цвета — опознавательный знак строки или карточки.
struct IconTile: View {
    let systemImage: String
    var tone: Tone = .brand
    var size: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tone.color)
            .frame(width: size, height: size)
            // Как значок в Dock: цветное стекло, светлее сверху, с бликом по кромке.
            .background(LinearGradient(colors: [tone.color.opacity(0.10), tone.color.opacity(0.2)],
                                       startPoint: .top, endPoint: .bottom), in: shape)
            .overlay { shape.strokeBorder(Theme.glassEdgeTop.opacity(0.7), lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}

/// Короткое состояние в капсуле: «Можно перенести», «Возвращено», «Сейф закрыт».
struct StatusPill: View {
    let title: String
    var systemImage: String?
    var tone: Tone = .neutral

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(title).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tone.color.opacity(0.13), in: Capsule())
    }
}

/// Крупное число с подписью в своей карточке: сводки над списками.
struct StatTile: View {
    let value: String
    let title: String
    var detail: String?
    let systemImage: String
    var tone: Tone = .brand

    var body: some View {
        Card(spacing: 10, fillsHeight: true) {
            IconTile(systemImage: systemImage, tone: tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text(title).font(.callout).foregroundStyle(.secondary)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Ярлык с моноширинным текстом: имена, которые бэкап пропускает.
struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.cardFill, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.cardStroke) }
    }
}

// MARK: - Шкалы

/// Отрезок шкалы между долями `from` и `to`. Это Shape, а не GeometryReader: размер он
/// узнаёт при раскладке. GeometryReader внутри строк списка заставлял таблицу пересчитывать
/// высоту строки прямо из своего делегата — AppKit ругался на реентерабельность и ломал отрисовку.
struct BarSegment: Shape {
    var from: Double = 0
    var to: Double
    var rounded = true

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(from, to) }
        set { from = newValue.first; to = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let start = rect.minX + rect.width * CGFloat(min(1, max(0, from)))
        var end = rect.minX + rect.width * CGFloat(min(1, max(0, to)))
        guard end > start else { return Path() }
        // Совсем маленькая доля видна точкой, а не пропадает совсем.
        if rounded { end = min(rect.maxX, max(end, start + rect.height)) }
        let bar = CGRect(x: start, y: rect.minY, width: end - start, height: rect.height)
        return rounded ? Path(roundedRect: bar, cornerRadius: rect.height / 2) : Path(bar)
    }
}

/// Горизонтальная шкала заполнения.
struct CapacityBar: View {
    let fraction: Double
    var tint: Color = Theme.brand
    var height: CGFloat = 6

    var body: some View {
        ZStack {
            Capsule().fill(Theme.track)
            BarSegment(to: fraction).fill(tint)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int((min(1, max(0, fraction)) * 100).rounded()))%")
    }
}

/// Шкала из нескольких частей подряд: на что делится занятое место.
struct StackedBar: View {
    struct Part {
        let fraction: Double
        let color: Color
    }

    let parts: [Part]
    var height: CGFloat = 8

    var body: some View {
        let starts = parts.indices.map { index in parts[..<index].reduce(0) { $0 + $1.fraction } }
        ZStack {
            Capsule().fill(Theme.track)
            ForEach(parts.indices, id: \.self) { index in
                BarSegment(from: starts[index], to: starts[index] + parts[index].fraction, rounded: false)
                    .fill(parts[index].color)
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

/// Кольцевая шкала с подписью в середине.
struct RingGauge<Center: View>: View {
    let fraction: Double
    var tint: Color = Theme.brand
    var lineWidth: CGFloat = 7
    @ViewBuilder let center: Center

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .padding(lineWidth / 2)
    }
}

// MARK: - Раскладка «потоком»

/// Раскладывает элементы слева направо и переносит на новую строку, когда место кончилось.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(subviews, width: proposal.width ?? .infinity)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !line.indices.isEmpty, line.width + spacing + size.width > width {
                lines.append(line)
                line = Line()
            }
            line.width += (line.indices.isEmpty ? 0 : spacing) + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}

// MARK: - Листы

/// Лист: значок и заголовок сверху, содержимое, кнопки внизу справа под чертой.
struct SheetLayout<Content: View, Actions: View>: View {
    let systemImage: String
    var tone: Tone = .brand
    let title: String
    var subtitle: String?
    var width: CGFloat = 480
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemImage: systemImage, tone: tone, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if let subtitle {
                            Text(subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.top, 1)
                }
                content
            }
            .padding(24)
            Divider()
            HStack(spacing: 8) {
                Spacer()
                actions
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: width)
    }
}
