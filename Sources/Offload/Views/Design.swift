import AppKit
import SwiftUI

// MARK: - Тема

/// Общий язык интерфейса: отступы, скругления и цвета.
///
/// Стиль — чёрно-белый, как у «Панели агентов»: белые карточки на тёплом сером, почти чёрный текст,
/// чёрная главная кнопка, заголовки с засечками. Тема одна — светлая, при любой теме macOS.
/// Цвет сообщает, а не украшает, и он приглушённый: зелёный — зашифровано и готово, янтарный —
/// лежит открыто или требует внимания, красный — ошибка, серый — трогать нельзя или делать нечего.
enum Theme {
    static let pagePadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 24
    static let cardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 13
    /// Шире колонка страницы не растягивается: на большом мониторе строки иначе читались бы с трудом.
    static let contentWidth: CGFloat = 980

    /// Фон страницы — тёплый серый; на нём белые карточки.
    static let background = hex(0xF6F6F4)
    static let panel = Color.white
    /// Поверхность внутри карточки: подложки значков, ярлыки, поля.
    static let soft = hex(0xF3F2EE)
    static let ink = hex(0x16181C)
    static let muted = hex(0x585D66)
    static let faint = hex(0x6A6F77)
    static let line = hex(0xE7E6E1)
    static let lineSoft = hex(0xF0EFEB)

    static let ok = hex(0x1F7A54)
    static let okSoft = hex(0xEAF3EE)
    static let warn = hex(0x8A6010)
    static let warnSoft = hex(0xFDF5E6)
    static let warnLine = hex(0xECD8A6)
    static let bad = hex(0xB3261E)
    static let badSoft = hex(0xFDEEEC)

    /// Действия, шкалы и выделение — чёрным, как главная кнопка панели.
    static let brand = ink
    static let cardFill = panel
    static let cardStroke = line
    /// Дорожка шкал и колец.
    static let track = hex(0xEDECE7)
    /// Тень карточки: едва заметная, карточка лежит на фоне, а не парит.
    static let shadow = Color(red: 20 / 255, green: 22 / 255, blue: 26 / 255).opacity(0.05)

    /// Заголовки с засечками (New York), как у панели.
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}

/// Что сообщает цвет. Один набор на всё приложение, чтобы янтарное везде значило одно и то же.
enum Tone {
    case good, caution, danger, neutral, brand, info

    var color: Color {
        switch self {
        case .good: return Theme.ok
        case .caution: return Theme.warn
        case .danger: return Theme.bad
        case .neutral: return Theme.faint
        case .brand, .info: return Theme.ink
        }
    }

    /// Подложка под цветом: плашки, значки, предупреждения.
    var soft: Color {
        switch self {
        case .good: return Theme.okSoft
        case .caution: return Theme.warnSoft
        case .danger: return Theme.badSoft
        case .neutral, .brand, .info: return Theme.soft
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
        .background(tint.map(Self.softFill) ?? Theme.cardFill, in: shape)
        .overlay { shape.strokeBorder(tint.map(Self.softLine) ?? Theme.cardStroke) }
        .shadow(color: tint == nil ? Theme.shadow : .clear, radius: 1, y: 1)
    }

    /// Подкрашенная карточка — мягкий фон своего цвета, как «Нужно от вас» в панели.
    private static func softFill(_ tint: Color) -> Color {
        if tint == Theme.warn { return Theme.warnSoft }
        if tint == Theme.bad { return Theme.badSoft }
        if tint == Theme.ok { return Theme.okSoft }
        return Theme.soft
    }

    private static func softLine(_ tint: Color) -> Color {
        tint == Theme.warn ? Theme.warnLine : tint.opacity(0.22)
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

/// Заголовок раздела, как в панели: тихая подпись заглавными с линией до края.
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
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.9)
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
            Rectangle().fill(Theme.line).frame(height: 1)
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
                    .font(Theme.serif(24))
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
                            .font(Theme.serif(20))
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
