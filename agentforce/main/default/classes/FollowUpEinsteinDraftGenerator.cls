/**
 * IFollowUpDraftGenerator backed by Prompt Builder (Einstein generative AI, Einstein Trust Layer).
 * Register by setting Follow_Up_Setting__mdt.Default.AI_Draft_Generator_Class__c = FollowUpEinsteinDraftGenerator.
 *
 * Templates (created per docs/agentforce.md), each with input "recommendation" and JSON output
 * {"subject": "", "message": "", "rationale": ""}:
 *   Follow_Up_Client_Draft            client check-ins and monthly status updates
 *   Follow_Up_Provider_Draft          provider records follow-ups
 *   Follow_Up_Stalled_Matter_Summary  internal stalled-matter rationale (no message)
 *
 * Performs callouts only; never DML. Output is validated by FollowUpDraftGuard and always reviewed by a person.
 */
public with sharing class FollowUpEinsteinDraftGenerator implements IFollowUpDraftGenerator {
    public static final String CLIENT_TEMPLATE = 'Follow_Up_Client_Draft';
    public static final String PROVIDER_TEMPLATE = 'Follow_Up_Provider_Draft';
    public static final String STALLED_TEMPLATE = 'Follow_Up_Stalled_Matter_Summary';
    private static final String APPLICATION_NAME = 'PromptTemplateGenerationsInvocable';

    public List<FollowUpDraftResult> generate(List<Follow_Up_Recommendation__c> recommendations) {
        List<FollowUpDraftResult> results = new List<FollowUpDraftResult>();
        for (Follow_Up_Recommendation__c rec : recommendations) {
            String templateName = templateFor(rec);
            FollowUpDraftResult result = new FollowUpDraftResult(rec.Id);
            if (templateName == null) {
                result.error = 'No prompt template for this recommendation type.';
                results.add(result);
                continue;
            }
            try {
                results.add(parse(rec.Id, invoke(templateName, rec.Id)));
            } catch (Exception e) {
                result.error = e.getMessage();
                results.add(result);
            }
        }
        return results;
    }

    @TestVisible
    private static String templateFor(Follow_Up_Recommendation__c rec) {
        if (rec.Audience__c == FollowUpConstants.AUDIENCE_CLIENT) {
            return CLIENT_TEMPLATE;
        }
        if (rec.Audience__c == FollowUpConstants.AUDIENCE_PROVIDER) {
            return PROVIDER_TEMPLATE;
        }
        if (rec.Recommendation_Type__c == FollowUpConstants.TYPE_STALLED_MATTER) {
            return STALLED_TEMPLATE;
        }
        return null;
    }

    /** Calls a flex prompt template with the recommendation as its only input; returns the raw generation. */
    public static String invoke(String templateName, Id recommendationId) {
        ConnectApi.WrappedValue recordValue = new ConnectApi.WrappedValue();
        recordValue.value = new Map<String, String>{ 'id' => recommendationId };
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.inputParams = new Map<String, ConnectApi.WrappedValue>{ 'Input:recommendation' => recordValue };
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = APPLICATION_NAME;
        input.isPreview = false;
        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output = ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
            templateName,
            input
        );
        if (output == null || output.generations == null || output.generations.isEmpty()) {
            throw new FollowUpException('The prompt template returned no generation.');
        }
        return output.generations[0].text;
    }

    /** Parses {"subject","message","rationale"} (tolerates Markdown code fences). */
    @TestVisible
    private static FollowUpDraftResult parse(Id recommendationId, String raw) {
        FollowUpDraftResult result = new FollowUpDraftResult(recommendationId);
        result.source = FollowUpConstants.DRAFT_AI;
        Map<String, Object> payload = parseJsonObject(raw);
        if (payload == null) {
            result.error = 'The AI response was not valid JSON.';
            return result;
        }
        result.subject = (String) payload.get('subject');
        result.message = (String) payload.get('message');
        result.rationale = (String) payload.get('rationale');
        result.success = String.isNotBlank(result.message) || String.isNotBlank(result.rationale);
        if (!result.success) {
            result.error = 'The AI response was empty.';
        }
        return result;
    }

    public static Map<String, Object> parseJsonObject(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String text = raw.trim();
        Integer start = text.indexOf('{');
        Integer finish = text.lastIndexOf('}');
        if (start < 0 || finish <= start) {
            return null;
        }
        try {
            Object parsed = JSON.deserializeUntyped(text.substring(start, finish + 1));
            return parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : null;
        } catch (JSONException e) {
            return null;
        }
    }
}
