import AppKit
import SwiftUI

// MARK: - Тема

/// Общий язык интерфейса: отступы, скругления, цвета и стекло.
///
/// Стиль — строгий чёрно-белый, как у Apple: белая страница, светло-серые карточки без рамок и теней,
/// шрифт SF, чёрные действия. Цветом ничего не украшается: состояния различаются значками и словами,
/// красный — только ошибка. Тема одна — светлая, при любой теме macOS.
///
/// Liquid Glass (macOS 26) — только у элементов управления, как у самой Apple: боковая колонка,
/// выделение в ней, кнопки, плавающая панель диска и сейфа. Содержимое на стекло не кладётся.
/// На macOS 14–15 те же места рисуются ровной заливкой.
enum Theme {
    static let pagePadding: CGFloat = 32
    static let sectionSpacing: CGFloat = 28
    static let cardPadding: CGFloat = 18
    static let cardRadius: CGFloat = 18
    /// Шире колонка страницы не растягивается: на большом мониторе строки иначе читались бы с трудом.
    static let contentWidth: CGFloat = 980

    static let background = Color.white
    /// Карточка — светло-серая пластина, как на apple.com.
    static let panel = hex(0xF5F5F7)
    /// Подложка внутри карточки: значки, ярлыки, выделение.
    static let soft = Color.white
    static let ink = hex(0x1D1D1F)
    static let muted = hex(0x6E6E73)
    static let faint = hex(0x86868B)
    static let line = hex(0xD2D2D7)
    static let lineSoft = hex(0xE8E8ED)

    /// Состояния — тем же чёрным: различает их значок (галочка, треугольник), а не цвет.
    static let ok = ink
    static let warn = ink
    static let bad = hex(0xD70015)
    static let badSoft = hex(0xFFF1F1)

    static let brand = ink
    static let cardFill = panel
    static let cardStroke = Color.clear
    /// Дорожка шкал и колец.
    static let track = lineSoft

    /// Крупный текст — SF, плотный и жирный, как заголовки Apple.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}

/// Что сообщает строка. Цвет у всего один — чёрный; красный только у ошибки.
enum Tone {
    case good, caution, danger, neutral, brand, info

    var color: Color {
        switch self {
        case .danger: return Theme.bad
        case .neutral: return Theme.faint
        case .good, .caution, .brand, .info: return Theme.ink
        }
    }

    /// Подложка значка и плашки: белая на серой карточке, розоватая — у ошибки.
    var soft: Color { self == .danger ? Theme.badSoft : Theme.soft }
}

// MARK: - Стекло

extension View {
    /// Liquid Glass на macOS 26 и новее, ровная заливка — на более старых.
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, fallback: Color = Theme.lineSoft, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(fallback, in: shape)
        }
    }

    /// Главная кнопка: чёрное стекло на macOS 26, чёрная капсула — раньше.
    @ViewBuilder
    func prominentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).tint(Theme.ink)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Theme.ink)
        }
    }

    /// Обычные кнопки всего окна: стекло на macOS 26, светлые капсулы — раньше.
    @ViewBuilder
    func glassButtons() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonBorderShape(.capsule)
        }
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
        .background(Theme.background)
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
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(tint == nil ? Theme.cardFill : tint == Theme.bad ? Theme.badSoft : Theme.background, in: shape)
        // Выделенная карточка (предупреждение) — белая с тонкой рамкой: на белой странице среди серых
        // она заметна без цвета.
        .overlay { shape.strokeBorder(tint == nil ? Color.clear : Theme.line) }
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
                .foregroundStyle(Theme.faint)
                .frame(width: 18)
            Text(title).font(.headline).foregroundStyle(Theme.ink)
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
            SectionHeader(title: title, number: number)
            Card(padding: 0, spacing: 0) {
                content
            }
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// Заголовок раздела над карточкой: коротко и жирно, без линий и заглавных.
struct SectionHeader: View {
    let title: String
    var number: Int?

    var body: some View {
        HStack(spacing: 10) {
            if let number {
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(Theme.ink, in: Circle())
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
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
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tone.color)
            .frame(width: size, height: size)
            .background(tone.soft, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
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
        .background(tone.soft, in: Capsule())
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
                    .font(Theme.display(24))
                    .monospacedDigit()
                Text(title).font(.callout).foregroundStyle(Theme.muted)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Theme.faint)
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
            .background(Theme.soft, in: Capsule())
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
                            .font(Theme.display(20))
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
        .background(Theme.panel)
    }
}

/// Кнопка-ссылка: чёрным, подчёркивается при наведении — вместо системной синей ссылки.
struct InkLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InkLink(configuration: configuration)
    }

    private struct InkLink: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? Theme.ink : Theme.faint)
                .underline(hovering && isEnabled)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
