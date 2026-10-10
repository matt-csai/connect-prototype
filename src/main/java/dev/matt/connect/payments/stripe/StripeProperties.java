package dev.matt.connect.payments.stripe;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Stripe credentials, bound from {@code stripe.*} (set from the STRIPE_SECRET_KEY and
 * STRIPE_WEBHOOK_SECRET environment variables).
 */
@ConfigurationProperties("stripe")
public record StripeProperties(String secretKey, String webhookSecret) {

  /** Never print the secrets: records otherwise include every component in toString(). */
  @Override
  public String toString() {
    return "StripeProperties[secretKey=<redacted>, webhookSecret=<redacted>]";
  }
}
