/**
 * Simple deterministic extractor for the MVP automatic-intake flow.
 *
 * It is intentionally small: it reads explicit labels from the inbound email body,
 * matches an existing Matter by Name, and optionally matches an existing provider by
 * email or name. It does not use clinical inference or invent missing values.
 */
public with sharing class SimpleAutomaticIntakeExtractor implements IAutomaticIntakeExtractor {
    public AutomaticIntakeService.ExtractedPayload extract(Automatic_Intake__c intakeRecord) {
        AutomaticIntakeService.ExtractedPayload payload = new AutomaticIntakeService.ExtractedPayload();
        payload.intakeId = intakeRecord.Id;
        payload.documentType = intakeRecord.Classification__c;
        payload.confidence = 0.95;
        payload.receivedDate = intakeRecord.Received_At__c == null
            ? Date.today()
            : intakeRecord.Received_At__c.date();

        String body = intakeRecord.Body_Text__c == null ? '' : intakeRecord.Body_Text__c;
        String matterName = extractValue(body, 'Matter reference:');
        String providerName = extractValue(body, 'Provider:');
        String providerEmail = extractValue(body, 'Provider Email:');
        String providerPhone = extractValue(body, 'Provider Phone:');
        String treatmentDateText = extractValue(body, 'Treatment Date:');
        String treatmentStatus = extractValue(body, 'Treatment Status:');
        String requestedDateText = extractValue(body, 'Requested Date:');

        if (String.isBlank(payload.documentType) || payload.documentType == 'Other') {
            payload.confidence = 0;
        }

        if (String.isBlank(matterName)) {
            payload.matterMatchUnambiguous = false;
            return payload;
        }

        List<Matter__c> matters = [
            SELECT Id, Name
            FROM Matter__c
            WHERE Name = :matterName
            LIMIT 2
        ];
        if (matters.size() != 1) {
            payload.matterMatchUnambiguous = false;
            return payload;
        }
        payload.matterId = matters[0].Id;
        payload.matterMatchUnambiguous = true;

        payload.providerName = providerName;
        payload.providerEmail = providerEmail;
        payload.providerPhone = providerPhone;

        if (String.isNotBlank(providerEmail)) {
            List<Medical_Provider__c> providers = [
                SELECT Id, Name, Email__c
                FROM Medical_Provider__c
                WHERE Email__c = :providerEmail
                LIMIT 2
            ];
            if (providers.size() == 1) {
                payload.providerId = providers[0].Id;
            } else if (providers.size() > 1) {
                payload.confidence = 0;
                payload.providerId = null;
            }
        }

        if (payload.providerId == null && String.isNotBlank(providerName)) {
            List<Medical_Provider__c> providersByName = [
                SELECT Id, Name, Email__c
                FROM Medical_Provider__c
                WHERE Name = :providerName
                LIMIT 2
            ];
            if (providersByName.size() == 1) {
                payload.providerId = providersByName[0].Id;
            } else if (providersByName.size() > 1) {
                payload.confidence = 0;
            }
        }

        if (payload.documentType == 'Treatment') {
            payload.treatmentDate = parseDate(treatmentDateText);
            payload.treatmentStatus = String.isBlank(treatmentStatus) ? null : treatmentStatus;
        } else if (payload.documentType == 'Medical Records' ||
                   payload.documentType == 'Medical Bills' ||
                   payload.documentType == 'Records and Bills') {
            payload.requestType = payload.documentType == 'Medical Records' ? 'Records' :
                payload.documentType == 'Medical Bills' ? 'Bills' : 'Records and Bills';
            payload.requestedDate = parseDate(requestedDateText);
        }

        return payload;
    }

    private static String extractValue(String body, String label) {
        if (String.isBlank(body) || String.isBlank(label)) return null;
        Integer start = body.toLowerCase().indexOf(label.toLowerCase());
        if (start < 0) return null;
        start += label.length();
        Integer end = body.indexOf('\n', start);
        if (end < 0) end = body.length();
        String value = body.substring(start, end).trim();
        return String.isBlank(value) ? null : value;
    }

    private static Date parseDate(String value) {
        if (String.isBlank(value)) return null;
        String cleaned = value.trim();
        try {
            if (cleaned.matches('\\d{4}-\\d{2}-\\d{2}')) {
                return Date.valueOf(cleaned);
            }
            if (cleaned.matches('\\d{1,2}/\\d{1,2}/\\d{4}')) {
                List<String> parts = cleaned.split('/');
                return Date.newInstance(Integer.valueOf(parts[2]), Integer.valueOf(parts[0]), Integer.valueOf(parts[1]));
            }
        } catch (Exception ignored) {
            // Validation in AutomaticIntakeService will route the intake to review.
        }
        return null;
    }
}
