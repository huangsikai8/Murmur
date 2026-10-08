import Foundation

/// Words that may appear at the start of a transcript without meaning a new
/// sentence has begun.
///
/// Shared by `CaretContinuation`, which asks the question of an insertion
/// point, and `WhisperEngine`, which asks it of a segment boundary. Kept in one
/// place because the two must never disagree: the list is the only thing
/// standing between a stray capital and somebody's name.
public enum SentenceOpeners {

    /// Words that can open a sentence position without opening a sentence.
    ///
    /// Every entry has to be a word that is **never** a proper noun and never a
    /// deliberate capital, because this list is the only thing standing between
    /// a stray capital and somebody's name. Nothing beginning with "i" is here:
    /// "I", "I'm" and "I've" are capitalized because they are that word, not
    /// because of where they fell.
    public static let safeToLowercase: Set<String> = [
        // Determiners and conjunctions.
        "the", "a", "an", "and", "but", "or", "nor", "so", "yet", "because",
        "if", "when", "while", "whereas", "though", "although", "unless",
        "until", "since", "whether", "that", "which", "who", "whom", "whose",
        // Pronouns and demonstratives.
        "this", "these", "those", "there", "they", "them", "their", "theirs",
        "it", "its", "he", "him", "his", "she", "her", "hers", "we", "us",
        "our", "ours", "you", "your", "yours", "me", "my", "mine", "one",
        // Prepositions.
        "of", "to", "for", "in", "on", "at", "by", "with", "from", "into",
        "onto", "about", "over", "under", "as", "after", "before", "during",
        "between", "among", "through", "against", "without", "within",
        "across", "around", "behind", "beyond", "beside", "toward", "towards",
        "upon", "per",
        // Verbs that carry no meaning on their own.
        "is", "are", "was", "were", "be", "been", "being", "am", "do", "does",
        "did", "has", "have", "had", "can", "could", "will", "would", "shall",
        "should", "may", "might", "must", "get", "got", "go", "going",
        // Adverbs and fillers, which is what a pause actually resumes on.
        "not", "no", "just", "like", "also", "even", "still", "only", "very",
        "really", "actually", "basically", "however", "otherwise", "then",
        "than", "too", "again", "always", "never", "maybe", "perhaps", "well",
        "okay", "right", "now", "here", "how", "what", "why", "where", "some",
        "any", "all", "both", "each", "every", "more", "most", "less", "least",
        "much", "many", "such", "same", "other", "another", "own",
        // The contractions those words actually arrive as.
        "there's", "theres", "they're", "theyre", "they've", "theyve",
        "it's", "its", "that's", "thats", "what's", "whats", "who's", "whos",
        "he's", "hes", "she's", "shes", "we're", "were", "we've", "weve",
        "you're", "youre", "you've", "youve", "isn't", "isnt", "aren't",
        "arent", "wasn't", "wasnt", "weren't", "werent", "don't", "dont",
        "doesn't", "doesnt", "didn't", "didnt", "can't", "cant", "won't",
        "wont", "wouldn't", "wouldnt", "shouldn't", "shouldnt", "couldn't",
        "couldnt", "hasn't", "hasnt", "haven't", "havent", "hadn't", "hadnt",
    ]
}
