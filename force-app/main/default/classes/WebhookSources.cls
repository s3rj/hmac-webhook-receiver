/**
 * Source configuration (Webhook_Source__mdt) and secrets (Webhook_Secret__c), with test overrides.
 */
public with sharing class WebhookSources {
    public class Source {
        public String name { get; private set; }
        public String signatureHeader { get; private set; }
        public String signaturePrefix { get; private set; }
        public WebhookSignature.Scheme scheme { get; private set; }
        public String timestampHeader { get; private set; }
        public Integer toleranceSeconds { get; private set; }
        public String eventIdHeader { get; private set; }
        public String eventIdPath { get; private set; }
        public String eventTypeHeader { get; private set; }
        public String eventTypePath { get; private set; }
        public Boolean active { get; private set; }

        public Source(String name) {
            this.name = name;
            this.scheme = WebhookSignature.Scheme.BODY;
            this.active = true;
        }

        public Source(Webhook_Source__mdt record) {
            this(record.DeveloperName);
            signatureHeader = record.Signature_Header__c;
            signaturePrefix = record.Signature_Prefix__c;
            scheme = WebhookSignature.schemeFor(record.Scheme__c);
            timestampHeader = record.Timestamp_Header__c;
            toleranceSeconds = record.Tolerance_Seconds__c == null ? null : record.Tolerance_Seconds__c.intValue();
            eventIdHeader = record.Event_Id_Header__c;
            eventIdPath = record.Event_Id_Path__c;
            eventTypeHeader = record.Event_Type_Header__c;
            eventTypePath = record.Event_Type_Path__c;
            active = record.Active__c;
        }

        public Source withSignature(String header, String prefix, WebhookSignature.Scheme scheme) {
            this.signatureHeader = header;
            this.signaturePrefix = prefix;
            this.scheme = scheme;
            return this;
        }

        public Source withTimestamp(String header, Integer tolerance) {
            this.timestampHeader = header;
            this.toleranceSeconds = tolerance;
            return this;
        }

        public Source withEventId(String header, String path) {
            this.eventIdHeader = header;
            this.eventIdPath = path;
            return this;
        }

        public Source withEventType(String header, String path) {
            this.eventTypeHeader = header;
            this.eventTypePath = path;
            return this;
        }

        public Source withActive(Boolean active) {
            this.active = active;
            return this;
        }

        /** The headers worth keeping on the event record. */
        public List<String> interestingHeaders() {
            List<String> names = new List<String>();
            for (String name : new List<String>{ signatureHeader, timestampHeader, eventIdHeader, eventTypeHeader }) {
                if (String.isNotBlank(name)) {
                    names.add(name);
                }
            }
            return names;
        }
    }

    @TestVisible
    private static Map<String, Source> sourceOverrides;
    @TestVisible
    private static Map<String, String> secretOverrides;
    private static Map<String, Source> cache;

    /** The source for a URL segment (case-insensitive), or null if none is configured or it is inactive. */
    public static Source find(String name) {
        if (String.isBlank(name)) {
            return null;
        }
        String key = name.toLowerCase();
        Map<String, Source> sources = sourceOverrides != null ? sourceOverrides : loadSources();
        Source source = sources.get(key);
        return source != null && source.active ? source : null;
    }

    /** The shared secret for a source, or null. */
    public static String secretFor(String sourceName) {
        if (secretOverrides != null) {
            return secretOverrides.get(sourceName.toLowerCase());
        }
        Webhook_Secret__c record = Webhook_Secret__c.getInstance(sourceName);
        return record == null ? null : record.Secret__c;
    }

    private static Map<String, Source> loadSources() {
        if (cache == null) {
            cache = new Map<String, Source>();
            for (Webhook_Source__mdt record : [
                SELECT DeveloperName, Signature_Header__c, Signature_Prefix__c, Scheme__c, Timestamp_Header__c, Tolerance_Seconds__c,
                    Event_Id_Header__c, Event_Id_Path__c, Event_Type_Header__c, Event_Type_Path__c, Active__c
                FROM Webhook_Source__mdt
                LIMIT 1000
            ]) {
                cache.put(record.DeveloperName.toLowerCase(), new Source(record));
            }
        }
        return cache;
    }
}
