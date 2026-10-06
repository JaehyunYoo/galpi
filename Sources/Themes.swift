import Foundation

struct CustomTheme: Codable, Identifiable {
    var id: String
    var name: String
    var colors: [String:String]
    var isDark: Bool

    init(id: String = UUID().uuidString, name: String, colors: [String:String]) throws {
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=60 else {throw AppError("테마 이름은 1~60자로 입력해 주세요.")}
        let keys=["paper","side","ink","dim","line","blue"]
        guard keys.allSatisfy({colors[$0]?.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil}) else {throw AppError("테마 색상은 #RRGGBB 형태로 입력해 주세요.")}
        self.id=id;self.name=name;self.colors=Dictionary(uniqueKeysWithValues:keys.map{($0,colors[$0]!.lowercased())})
        let rgb=UInt32(colors["paper"]!.dropFirst(),radix:16)!
        let red=Double((rgb >> 16) & 255)
        let green=Double((rgb >> 8) & 255)
        let blue=Double(rgb & 255)
        self.isDark=(0.2126*red + 0.7152*green + 0.0722*blue)<140
    }
}

extension Store {
    func saveTheme(name:String,colors:[String:String],id:String? = nil) throws -> CustomTheme {
        let old=library.preferences
        if let id,!(old.customThemes ?? []).contains(where:{$0.id==id}) {throw AppError("수정할 테마를 찾지 못했어요.")}
        let theme=try CustomTheme(id:id ?? UUID().uuidString,name:name,colors:colors)
        var themes=old.customThemes ?? []
        if let i=themes.firstIndex(where:{$0.id==theme.id}){themes[i]=theme}else{themes.append(theme)}
        library.preferences.customThemes=themes;library.preferences.theme=theme.id
        do {try persist()}catch{library.preferences=old;throw error}
        return theme
    }
    func removeTheme(_ id:String) throws {
        let old=library.preferences
        guard let theme=(old.customThemes ?? []).first(where:{$0.id==id}) else {throw AppError("테마를 찾지 못했어요.")}
        library.preferences.customThemes=(old.customThemes ?? []).filter{$0.id != id}
        if old.theme==id {library.preferences.theme=theme.isDark ? "dark":"light"}
        do {try persist()}catch{library.preferences=old;throw error}
    }
}
