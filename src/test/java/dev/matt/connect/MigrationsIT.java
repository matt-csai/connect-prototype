package dev.matt.connect;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * Brief test 1: the Flyway migrations apply cleanly to an empty Postgres, and the app starts on top
 * of them. Runs in `mvn verify` (Testcontainers needs Docker, which stays out of the sandbox).
 */
@SpringBootTest
@Testcontainers
class MigrationsIT {

  private static final String FAKE_SUFFIX = "FAKE_KEY_FOR_INTEGRATION_TESTS";

  @Container @ServiceConnection
  static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");

  /** Fake keys, assembled at runtime so the source holds no key-shaped literal. */
  @DynamicPropertySource
  static void stripeProperties(DynamicPropertyRegistry registry) {
    registry.add("stripe.secret-key", () -> "sk_test_" + FAKE_SUFFIX);
    registry.add("stripe.webhook-secret", () -> "whsec_" + FAKE_SUFFIX);
    // application.yml has no default DB password; the Testcontainers connection replaces it.
    registry.add("DB_PASSWORD", () -> "unused-with-testcontainers");
  }

  @Autowired JdbcClient jdbc;

  @Test
  void appliesAllMigrationsToAnEmptyDatabase() {
    Integer failed =
        jdbc.sql("select count(*) from flyway_schema_history where not success")
            .query(Integer.class)
            .single();
    List<String> columns =
        jdbc.sql(
                """
                select column_name from information_schema.columns
                where table_name = 'resellers' order by ordinal_position
                """)
            .query(String.class)
            .list();

    assertThat(failed).isZero();
    assertThat(columns)
        .containsExactly(
            "id",
            "display_name",
            "stripe_account_id",
            "charges_enabled",
            "payouts_enabled",
            "details_submitted",
            "created_at",
            "updated_at");
  }

  @Test
  void resellersCanExistBeforeTheirStripeAccountButAnAccountBelongsToOneReseller() {
    insertReseller(null);
    insertReseller(null);
    insertReseller("acct_IT_UNIQUE_1");

    assertThatThrownBy(() -> insertReseller("acct_IT_UNIQUE_1"))
        .isInstanceOf(DuplicateKeyException.class);
  }

  @Test
  void rejectsStripeAccountIdsThatAreNotAccountIds() {
    assertThatThrownBy(() -> insertReseller(""))
        .isInstanceOf(DataIntegrityViolationException.class);
    assertThatThrownBy(() -> insertReseller("cus_NOT_AN_ACCOUNT"))
        .isInstanceOf(DataIntegrityViolationException.class);
  }

  @Test
  void updatedAtMovesOnEveryUpdate() {
    UUID id = UUID.randomUUID();
    OffsetDateTime longAgo = OffsetDateTime.parse("2000-01-01T00:00:00Z");
    jdbc.sql("insert into resellers (id, display_name, updated_at) values (?, ?, ?)")
        .params(id, "Before", longAgo)
        .update();

    jdbc.sql("update resellers set charges_enabled = true where id = ?").param(id).update();

    OffsetDateTime updatedAt =
        jdbc.sql("select updated_at from resellers where id = ?")
            .param(id)
            .query(OffsetDateTime.class)
            .single();
    assertThat(updatedAt).isAfter(longAgo);
  }

  private void insertReseller(String stripeAccountId) {
    jdbc.sql("insert into resellers (id, display_name, stripe_account_id) values (?, ?, ?)")
        .params(UUID.randomUUID(), "Test reseller", stripeAccountId)
        .update();
  }
}
