import Foundation

/// The parts of every prompt that the app itself depends on: the output formats it parses and the task texts
/// (plan.md Appendix B.2). They are constants in code, never settings, so editing the rubric or the system prompts
/// cannot break parsing.
///
/// Every value is the text printed in Appendix B.2, character for character, with no final line break. Two things
/// printed there are not prompt text and are not here: the "← only when …" notes beside the optional lines, and the
/// shorthand `{same optional lines}`, which is written out. Text in braces is a placeholder for ReviewEngine's
/// PromptBuilder. Three kinds occur:
///
/// - **Values.** `{paper text}`, `{text of the part}`, `{i}`, `{n}`, `{a}`, `{b}`, `{notes}` and `{titles}` are
///   replaced by the value they name.
/// - **Optional lines.** `{Reviewer's notes: …}`, `{Target journal: …}` and
///   `{Comments already made, do not repeat them: title; title; …}` each stand alone on a line, at the end of the two
///   `taskReview…` texts. Such a line becomes the text between the braces, with the real value in place of what
///   follows the first colon; when its condition does not hold (no reviewer notes, no target venue, no existing
///   comments) the whole line is removed together with its line break.
/// - **The marker `{if i > 1:}`** in `taskPart` is always removed together with its line break. For the first part
///   (i == 1) the two lines after it and the empty line that follows them are removed too.
///
/// `review` and `revision` contain no placeholders (the two "…" lines in `revision` are part of the text).
public enum FormatSpec {                                  // Appendix B.2: constants in code, never settings
    public static var review: String { formatReview }                  // FORMAT_REVIEW
    public static var revision: String { formatRevision }              // FORMAT_REVISION
    /// One text for the whole user turn. The line `{paper text}` splits it: what stands before that line introduces
    /// the paper and goes, with the rendered paper, before the cache boundary; what follows it is the task and goes
    /// after the cache boundary.
    public static var taskReviewText: String { taskReviewTextMode }    // TASK_REVIEW, text mode
    /// Follows the `.pdf` part and the cache boundary. (Appendix B.2 abbreviates its last three lines as
    /// `{same optional lines}`; they are written out here.)
    public static var taskReviewPDF: String { taskReviewPDFMode }      // TASK_REVIEW, PDF mode
    public static var taskPart: String { taskPartText }                // TASK_PART
    public static var taskWhole: String { taskWholeText }              // TASK_WHOLE
    public static var taskContinue: String { taskContinueText }        // TASK_CONTINUE

    // ---- The texts of Appendix B.2. Do not reflow them: every line break is part of the prompt. ----

    private static let formatReview = """
        OUTPUT FORMAT. Your output is read by a program, so follow this exactly.

        Write each comment as a block:

        @@COMMENT
        kind: major | minor | question | strength
        category: one of the category ids listed above
        page: the PDF page number of the quoted passage
        quote: a passage copied exactly from the manuscript, 6 to 40 words, on one line
        title: at most 12 words
        body:
        The comment itself: what the problem is, why it matters for the paper's conclusions, and exactly where it is (section, equation, table, figure).
        suggestion:
        A concrete way to resolve it. Leave this field out if you have none; do not write "N/A" or "none".
        @@END

        Rules:
        - Copy the quote character for character from the manuscript so that it can be found. Do not paraphrase it, do not shorten it with "...", do not put quotation marks around it. For a comment about an equation, table or figure, quote the sentence that introduces or refers to it. For a comment about something missing, quote the passage where it should have been addressed.
        - One issue per comment. Do not number the comments.
        - "major" threatens the paper's main conclusions. "minor" should be fixed but does not. "question" is something whose answer could change your assessment. "strength" is something done well: write at most two, and only if you can say what is unusual about it; a compliment that would fit any paper is not a comment.
        - Write nothing outside the blocks: no introduction, no summary, no closing remarks.
        - Most serious comments first. Do not pad: a clean paper gets few comments.
        - After the last comment write a line containing only @@DONE
        """

    private static let formatRevision = """
        If the discussion changes what the comment should say, end your reply with the revised comment in exactly this form:
        @@REVISED
        kind: major | minor | question | strength
        title: at most 12 words
        body:
        …
        suggestion:
        …
        @@END
        If the comment should be dropped, end your reply with a line containing only @@WITHDRAW
        Otherwise write no block.
        """

    private static let taskReviewTextMode = """
        The manuscript follows as text extracted from a PDF. Lines of the form [[page N]] mark where PDF page N begins; they are not part of the manuscript, and each is placed at the nearest sentence boundary.
        Extraction leaves artefacts: words run together without spaces, odd hyphenation, and equations and tables broken into fragments. These are not errors in the manuscript; do not comment on them. If you cannot read a formula or a table well enough to check it, say that you could not check it.

        {paper text}
        Write your referee comments on this manuscript in the required format.
        {Reviewer's notes: …}
        {Target journal: …}
        {Comments already made, do not repeat them: title; title; …}
        """

    private static let taskReviewPDFMode = """
        The manuscript is the attached PDF. Use PDF page numbers: the first page of the file is page 1.
        Write your referee comments on this manuscript in the required format.
        {Reviewer's notes: …}
        {Target journal: …}
        {Comments already made, do not repeat them: title; title; …}
        """

    private static let taskPartText = """
        The manuscript is long, so you are reading it in parts, as text extracted from a PDF. This is part {i} of {n}: PDF pages {a} to {b}. Lines of the form [[page N]] mark where PDF page N begins. Words run together, odd hyphenation and broken equations or tables are artefacts of extraction; do not comment on them.

        {if i > 1:}
        Your notes on the earlier parts:
        {notes}

        {text of the part}

        First write comments on this part in the required format. Comment only on what you can judge from this part and your notes; keep issues that need the whole paper for the end.
        Then write a line containing only @@NOTES and, after it, updated notes for yourself, at most 350 words: the paper's question, design and data, key assumptions, the main claims with the numbers that support them, notation, and what you want to check against later parts. Include up to 8 short passages copied exactly from the manuscript that you may want to cite later, each as: p.N: passage
        End with a line containing only @@DONE
        """

    private static let taskWholeText = """
        You have now read the whole manuscript in parts. Your notes:
        {notes}

        Comments you already made: {titles}

        Write any further comments that only make sense for the paper as a whole: conclusions against evidence, hidden assumptions, how far the results travel, position in the debate, missing work. Use the required format. For each quote use one of the passages copied in your notes. If you have nothing to add, write only @@DONE
        """

    private static let taskContinueText = """
        Your previous answer was cut off. Comments already written (do not repeat them): {titles}
        Continue with the remaining comments in the same format and end with a line containing only @@DONE
        """
}
