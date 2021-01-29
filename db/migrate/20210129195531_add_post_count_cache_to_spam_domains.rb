# frozen_string_literal: true

class AddPostCountCacheToSpamDomains < ActiveRecord::Migration[5.2]
  def up
    execute <<-SQL
      ALTER TABLE spam_domains ADD COLUMN (
        tp_count INTEGER UNSIGNED NOT NULL DEFAULT 0,
        fp_count INTEGER UNSIGNED NOT NULL DEFAULT 0,
        naa_count INTEGER UNSIGNED NOT NULL DEFAULT 0
      )
    SQL

    execute <<-SQL
      CREATE TRIGGER trigger_posts_spam_domains_insert
        AFTER INSERT ON posts_spam_domains FOR EACH ROW
        BEGIN
          SELECT is_tp, is_fp, is_naa INTO @tp, @fp, @naa
            FROM posts
            WHERE id = NEW.post_id;
          UPDATE spam_domains SET
              tp_count = tp_count + @tp,
              fp_count = fp_count + @fp,
              naa_count = naa_count + @naa
            WHERE id = NEW.spam_domain_id;
        END
    SQL

    execute <<-SQL
      CREATE TRIGGER trigger_posts_spam_domains_delete
        AFTER DELETE ON posts_spam_domains FOR EACH ROW
        BEGIN
          SELECT is_tp, is_fp, is_naa INTO @tp, @fp, @naa
            FROM posts
            WHERE id = OLD.post_id;
          UPDATE spam_domains SET
              tp_count = tp_count - @tp,
              fp_count = fp_count - @fp,
              naa_count = naa_count - @naa
            WHERE id = OLD.spam_domain_id;
        END
    SQL

    execute <<-SQL
      CREATE TRIGGER trigger_posts_update
        AFTER UPDATE ON posts FOR EACH ROW
        IF OLD.is_tp <> NEW.is_tp OR
           OLD.is_fp <> NEW.is_fp OR
           OLD.is_naa <> NEW.is_naa THEN
          UPDATE spam_domains, posts_spam_domains SET
              tp_count = tp_count - OLD.is_tp + NEW.is_tp,
              fp_count = fp_count - OLD.is_fp + NEW.is_fp,
              naa_count = naa_count - OLD.is_naa + NEW.is_naa
            WHERE posts_spam_domains.post_id = NEW.id AND
                  spam_domains.id = posts_spam_domains.spam_domain_id;
        END IF
    SQL

    # Necessary because triggers won't fire on cascade delete
    execute <<-SQL
      CREATE TRIGGER trigger_posts_delete
        AFTER DELETE ON posts FOR EACH ROW
        BEGIN
          UPDATE spam_domains, posts_spam_domains SET
              tp_count = tp_count - OLD.is_tp,
              fp_count = fp_count - OLD.is_fp,
              naa_count = naa_count - OLD.is_naa
            WHERE posts_spam_domains.post_id = OLD.id AND
                  spam_domains.id = posts_spam_domains.spam_domain_id;
        END
    SQL

    # Calculate current cache value
    execute <<-SQL
      UPDATE
          spam_domains,
          (SELECT
               spam_domains.id AS id,
               sum(is_tp) AS tp,
               sum(is_fp) AS fp,
               sum(is_naa) AS naa
             FROM spam_domains
             INNER JOIN posts_spam_domains
               ON posts_spam_domains.spam_domain_id = spam_domains.id
             INNER JOIN posts
               ON posts_spam_domains.post_id = posts.id
             GROUP BY spam_domains.id) src
        SET
            tp_count = tp,
            fp_count = fp,
            naa_count = naa
        WHERE spam_domains.id = src.id
    SQL
  end

  def down
    execute 'DROP TRIGGER trigger_posts_spam_domains_insert'
    execute 'DROP TRIGGER trigger_posts_spam_domains_delete'
    execute 'DROP TRIGGER trigger_posts_update'
    execute 'DROP TRIGGER trigger_posts_delete'
    execute <<-SQL
      ALTER TABLE spam_domains
        DROP COLUMN tp_count,
        DROP COLUMN fp_count,
        DROP COLUMN naa_count
    SQL
  end
end
