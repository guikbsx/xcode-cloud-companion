import Foundation

nonisolated enum FailureInsightAttempt: Sendable, Equatable {
    case first
    case retry(rejected: String, problems: [FailureInsightValidator.HeadlineProblem])

    var isRetry: Bool {
        if case .retry = self { return true }
        return false
    }
}

nonisolated enum FailureInsightLanguage: Sendable, Equatable {
    case french
    case english

    init(locale: Locale = .current) {
        self = locale.language.languageCode?.identifier == "fr" ? .french : .english
    }

    var locale: Locale {
        Locale(identifier: self == .french ? "fr_FR" : "en_US")
    }
}

/// The model's instructions. They are prompts, not interface: they live here, not in the string catalog, and the model
/// answers in French only when they are written in French.
nonisolated enum FailureInsightPrompts {
    static let minimumTestsForGroups = 6
    static let firmerHeadlineLimit = 70

    static func wantsGroups(_ input: FailureInsightInput) -> Bool {
        input.shownTestCount >= minimumTestsForGroups
    }

    static func instructions(for input: FailureInsightInput, language: FailureInsightLanguage, attempt: FailureInsightAttempt) -> String {
        switch language {
        case .english: english(category: input.category, groups: wantsGroups(input), firmer: attempt.isRetry)
        case .french: french(category: input.category, groups: wantsGroups(input), firmer: attempt.isRetry)
        }
    }

    static func request(for input: FailureInsightInput, language: FailureInsightLanguage, attempt: FailureInsightAttempt) -> String {
        let data = (language == .french ? "Données du build :\n\n" : "Build data:\n\n") + input.text
        guard case .retry(let rejected, let problems) = attempt else { return data }
        let reasons = problems.map { reason($0, language: language) }.joined(separator: language == .french ? " ; " : "; ")
        if language == .french {
            return data + "\n\nTitre précédent, refusé : « \(rejected) »\nRaisons : \(reasons).\nÉcris un autre titre."
        }
        return data + "\n\nPrevious headline, rejected: \"\(rejected)\"\nReasons: \(reasons).\nWrite another headline."
    }

    private static func reason(_ problem: FailureInsightValidator.HeadlineProblem, language: FailureInsightLanguage) -> String {
        let french = language == .french
        let limit = FailureInsightValidator.maximumHeadlineLength
        switch problem {
        case .empty: return french ? "il était vide" : "it was empty"
        case .tooLong(let count): return french ? "il faisait \(count) caractères, la limite est \(limit)" : "it had \(count) characters, the limit is \(limit)"
        case .notOneSentence: return french ? "il avait plusieurs phrases" : "it had several sentences"
        case .unknownFileName(let name): return french ? "il citait \(name), absent des données" : "it named \(name), which is not in the data"
        case .unknownNumber(let number): return french ? "il contenait le nombre \(number), absent des données" : "it contained the number \(number), which is not in the data"
        }
    }

    private static func english(category: FailureCategory, groups: Bool, firmer: Bool) -> String {
        var text = """
        You read data about one failed Xcode Cloud build and write a headline for it. Use only the data given: never invent a file name, \
        a test name or a number. Give no advice and no fix.
        The failure category is already decided by the app, take it as a fact and do not contradict it: \(category.rawValue), \(englishMeaning(category)).
        Headline: one short sentence in English, at most 12 words and 90 characters, in your own words, saying what broke. Do not copy the error message. Name a file or a test class only when the data names it. \
        Error messages, file names and test names stay as written in the data.
        """
        if groups {
            text += """

            Groups: when several failed tests share a cause, group them. Give each group a title of at most 60 characters naming the shared cause, \
            and the [n] indexes of its tests. Each test is in at most one group. Leave unrelated tests out. Give two groups or more, or none.
            """
        }
        if firmer {
            text += "\nYour previous headline was rejected. Write a much shorter one: at most 8 words and \(firmerHeadlineLimit) characters, one sentence, no file name and no number unless it appears word for word in the data."
        }
        return text
    }

    private static func french(category: FailureCategory, groups: Bool, firmer: Bool) -> String {
        var text = """
        Tu lis les données d'un build Xcode Cloud en échec et tu écris un titre pour lui. Réponds toujours en français. Appuie-toi uniquement sur les données : \
        n'invente ni nom de fichier, ni nom de test, ni nombre. Ne donne ni conseil ni correctif.
        La catégorie de l'échec est déjà décidée par l'application, prends-la pour un fait et ne la contredis pas : \(category.rawValue), \(frenchMeaning(category)).
        Titre (headline) : une courte phrase en français, de 12 mots et 90 caractères au plus, avec tes propres mots, qui dit ce qui a cassé. Ne recopie pas le message d'erreur. Cite un fichier ou une classe de test seulement si les données le nomment. \
        Les messages d'erreur, les noms de fichiers et de tests restent tels qu'écrits dans les données.
        """
        if groups {
            text += """

            Groupes : quand plusieurs tests en échec ont une cause commune, regroupe-les. Donne à chaque groupe un titre en français de 60 caractères au plus qui nomme la cause commune, \
            et les index [n] de ses tests. Chaque test est dans un seul groupe. Laisse de côté les tests sans rapport. Donne au moins deux groupes, ou aucun.
            """
        }
        if firmer {
            text += "\nTon titre précédent a été refusé. Écris-en un beaucoup plus court : 8 mots et \(firmerHeadlineLimit) caractères au plus, une seule phrase, sans nom de fichier ni nombre sauf s'il figure mot pour mot dans les données."
        }
        return text
    }

    private static func englishMeaning(_ category: FailureCategory) -> String {
        switch category {
        case .compilation: "the code does not compile, with errors in source files"
        case .tests: "tests failed"
        case .flakyTest: "tests that both passed and failed, so likely flaky tests and not a code regression"
        case .signing: "a code signing or provisioning problem"
        case .configuration: "the Xcode Cloud workflow or the project is misconfigured, for example an unsupported test destination or a missing scheme; it is not a code error"
        case .distribution: "the build compiled but its distribution failed: exporting the archive, or preparing or uploading the build to App Store Connect; it is not a code error"
        case .infrastructure: "Xcode Cloud or the build machine failed, with no error or failed test reported"
        case .other: "no clear cause, so say only what the data shows"
        }
    }

    private static func frenchMeaning(_ category: FailureCategory) -> String {
        switch category {
        case .compilation: "le code ne compile pas, avec des erreurs dans des fichiers source"
        case .tests: "des tests ont échoué"
        case .flakyTest: "des tests ont à la fois réussi et échoué, donc probablement instables et sans régression du code"
        case .signing: "un problème de signature du code ou de profil de provisionnement"
        case .configuration: "le workflow Xcode Cloud ou le projet est mal réglé, par exemple une destination de test non prise en charge ou un schéma introuvable ; ce n'est pas une erreur de code"
        case .distribution: "le code a compilé mais la distribution a échoué : export de l'archive, ou préparation ou envoi du build vers App Store Connect ; ce n'est pas une erreur de code"
        case .infrastructure: "Xcode Cloud ou la machine de build a échoué, sans erreur ni test en échec rapporté"
        case .other: "pas de cause claire, dis seulement ce que montrent les données"
        }
    }
}
