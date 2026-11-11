# Dictation formatting reference

Basic and Advanced cleanup apply local formatting rules to English transcripts from Parakeet and
other speech engines. To use these rules without loading a cleanup model, choose **Basic** or **Advanced**
under **Settings → Dictation → Text cleanup** and turn off automatic transforms under **After dictation**.
Automatic transforms can load the selected cleanup engine independently.

| Formatting | Example transcript | Expected result |
| --- | --- | --- |
| Currency | The total is forty-five dollars and ninety-nine cents. | The total is $45.99. |
| Digit amount | It costs 1,200 dollars. | It costs $1,200. |
| Signed currency | The balance is minus five dollars. | The balance is -$5. |
| Named date | Ship on the twenty-fourth of June, twenty twenty-seven. | Ship on June 24, 2027. |
| Month first | It opened on June first, two thousand and five. | It opened on June 1, 2005. |
| Clock time | Let's meet at nine thirty in the morning. | Let's meet at 9:30 AM. |
| Time range | Open from nine AM to five PM. | Open from 9:00 AM to 5:00 PM. |
| Relative clock time | Call at quarter to nine PM. | Call at 8:45 PM. |
| Spoken minute offset | Call at twenty five to nine PM. | Call at 8:35 PM. |
| 24-hour time | The shift starts at 0730 hours. | The shift starts at 07:30. |
| Noon and midnight | We open at noon and close at midnight. | We open at 12:00 PM and close at 12:00 AM. |
| Percentage | The rate is twelve point five per cent. | The rate is 12.5%. |
| Metric measurement | It holds 1.50 litres. | It holds 1.50 L. |
| Temperature | It is minus five degrees Celsius. | It is -5 °C. |
| Storage | The file is sixteen megabytes. | The file is 16 MB. |
| Fraction | Add three quarters of a cup. | Add 3/4 of a cup. |
| Decimal | The score was three point one four. | The score was 3.14. |
| Email | Send it to ana at example dot com. | Send it to ana@example.com. |
| Website | Visit w w w dot example dot com. | Visit www.example.com. |
| Phone number | Call me at two zero two five five five zero one two three. | Call me at 202-555-0123. |
| Fillers | Um, send Ana the agenda. | Send Ana the agenda. |
| Stutters | I I I will send the agenda. | I will send the agenda. |
| Repeated short words | Send the the agenda. | Send the agenda. |
| Clear weekday correction | Send it on Friday, no sorry, Monday. | Send it on Monday. |
| Spoken punctuation | Is the room booked, insert question mark. | Is the room booked? |
| Line break | Send the agenda. New line. Keep a copy. | Two lines, with “Keep a copy.” on the second. |
| Paragraph break | Send the agenda. New paragraph. Keep a copy. | Two paragraphs separated by a blank line. |
| Bulleted list | Tasks: bullet one call Ana bullet two book a room. | Two bullets under “Tasks:”. |
| Numbered list | First, open the file, second, check it, third, send it. | Three numbered steps. |
| Ordered steps | First open the file and then check the figures, and finally send the draft. | Three numbered steps. |
| Stated item count | I have two action items. Send the invoice. Confirm the delivery date. | Two bullets under “I have two action items:”. |
| List heading | Packing list: a charger, a notebook and a pen. | Three bullets under “Packing list:”. |
| Topic change | The invoice is ready. On a separate note, the delivery moved to Friday. | A new paragraph starting with “On a separate note”. |
| Greeting and sign-off | Hi Ana, the invoice is ready. Kind regards, Maya. | The greeting, message, and sign-off on separate lines. |

The examples from Stutters onward require Advanced. It keeps existing paragraph breaks and can
add breaks at clear topic changes, recaps, speaker handoffs, and sentence boundaries in long blocks.
It keeps transition phrases such as “Moving on to delivery” in the transcript. A greeting and a
conventional sign-off with a name can mark the start and end of a message.

The currency rule covers dollars, euros, pounds sterling, Ghanaian cedis, yen, and explicitly
named Indian rupees. It accepts spoken whole amounts up to 999, larger amounts that speech
recognition already wrote as digits, and supported decimals or minor units. A bare “pounds”
can describe weight, so the rule requires “sterling” for £. Named dates work in either
spoken order, with optional years such as “twenty oh five” and “two thousand and five.”
The formatter checks the day against the month and any supplied year. A time can omit AM or PM when the
context still identifies it as a time, as in “at nine thirty tomorrow,” which becomes
“at 9:30 tomorrow.” A bare “at nine” stays as spoken.

Percentages and supported measurements accept whole values, decimals, and explicit signs.
Measurement units cover common metric lengths, masses, and volumes, plus Celsius and Fahrenheit
and kilobytes through terabytes. “Percentage points” stays distinct from a percentage.

Advanced recognizes repeated “bullet point,” sequential labels such as “number one” and “number two,”
and phrases such as “first,” “next,” and “finally.” Inferred sequences without a heading need three
items. A heading can introduce a shorter sequence or an inline list with distinct items. If it states
an item count, the count must match. For explicit commands, say “start numbered list,” “next item”
between entries, and “exit list” before returning to prose.

After “insert,” punctuation commands include comma, period, full stop, question mark, exclamation
mark, colon, semicolon, and ellipsis. They work in the comma-delimited form shown above.

The rules skip transcripts with quotation or code markers and skip lines that look like links,
email addresses, or paths. They leave out-of-scope values such as unsupported spoken scales and invalid
dates in the transcript. Phone formatting requires an explicit cue and ten spoken digits.
Websites need a spoken “www” prefix and emails need a spoken “at” and “dot” with a supported
domain ending. The formatter has a 16 KB input limit and a 30 ms time budget. If either limit
is exceeded, Basic keeps its filler removal and Advanced keeps the original text.

**Off** skips cleanup. **Basic** removes common fillers and formats spoken values.
**Advanced** adds the corrections and formatting commands above.
**Smart** uses the selected cleanup engine for context-dependent edits. **After dictation** can
apply a separate transform such as Shorten or Prompt Engineer.

Public references include [Microsoft’s speech formatting examples](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/display-text-format),
[NVIDIA NeMo’s spoken and written test pairs](https://github.com/NVIDIA/NeMo-text-processing/tree/main/tests/nemo_text_processing/en/data_inverse_text_normalization),
[Google’s number style guide](https://developers.google.com/style/numbers), and
[Apple’s dictation commands](https://support.apple.com/guide/mac-help/commands-for-dictating-text-mh40695/mac).
Fractions, standalone decimals, and the spoken contact formats use
[FluidInference’s text-processing-rs](https://github.com/FluidInference/text-processing-rs/tree/v0.3.3).
List cues draw on [Word dictation commands](https://support.microsoft.com/en-us/word/dictate-help-internal)
and [Microsoft’s list introductions](https://learn.microsoft.com/en-us/style-guide/punctuation/colons).
Paragraph cues use sentence position as evidence for a change in topic or purpose.
[Hirschberg and Litman’s research on cue phrases](https://aclanthology.org/J93-3003/)

See [Dictation settings](dictation.md#text-cleanup-and-transforms), the
[formatter](../../Tinycast/Features/Dictation/Model/DictationTextFormatter.swift), and its
[expected input and output examples](../../Tests/dictation-advanced-test.swift).
