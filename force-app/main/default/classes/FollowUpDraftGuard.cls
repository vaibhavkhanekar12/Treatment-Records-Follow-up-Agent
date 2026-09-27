/**
 * Deterministic post-generation guardrail for AI output. Any AI draft or rationale that mentions a
 * restricted topic (Follow_Up_Setting__mdt.Restricted_Terms__c: settlement, liability, diagnosis, ...)
 * is discarded and the template draft is kept. This does not replace human review; it prevents an
 * obviously out-of-scope AI draft from ever reaching the approval queue.
 */
public with sharing class FollowUpDraftGuard {
    /** Returns the first restricted term found (whole-word, case-insensitive), or null. */
    public static String findRestrictedTerm(String text) {
        if (String.isBlank(text)) {
            return null;
        }
        for (String term : FollowUpConfig.restrictedTerms()) {
            Pattern termPattern = Pattern.compile('(?i)\\b' + Pattern.quote(term) + '\\b');
            if (termPattern.matcher(text).find()) {
                return term;
            }
        }
        return null;
    }

    public static Boolean isSafe(String subject, String message, String rationale) {
        return findRestrictedTerm(subject) == null && findRestrictedTerm(message) == null && findRestrictedTerm(rationale) == null;
    }
}
