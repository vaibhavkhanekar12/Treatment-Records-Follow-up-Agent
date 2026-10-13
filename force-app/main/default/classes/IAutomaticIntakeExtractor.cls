/**
 * Implement this contract with an extraction capability licensed and configured in the target org.
 * Implementations must return only evidence-backed fields and explicitly report match ambiguity.
 */
public interface IAutomaticIntakeExtractor {
    AutomaticIntakeService.ExtractedPayload extract(Automatic_Intake__c intakeRecord);
}