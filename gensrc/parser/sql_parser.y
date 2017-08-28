// Copyright 2017 The Apache Software Foundation
// Modifications copyright (C) 2017, Baidu.com, Inc.

// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

package com.baidu.palo.analysis;

import com.baidu.palo.common.Version;
import com.baidu.palo.common.AnalysisException;
import com.baidu.palo.catalog.AccessPrivilege;
import com.baidu.palo.catalog.Column;
import com.baidu.palo.catalog.KeysType;
import com.baidu.palo.catalog.PrimitiveType;
import com.baidu.palo.catalog.ColumnType;
import com.baidu.palo.catalog.Type;
import com.baidu.palo.catalog.View;
import com.baidu.palo.catalog.AggregateType;
import com.baidu.palo.analysis.PartitionKeyDesc;
import com.baidu.palo.analysis.UnionStmt.UnionOperand;
import com.baidu.palo.analysis.UnionStmt.Qualifier;
import com.baidu.palo.mysql.MysqlPassword;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.math.BigDecimal;
import java_cup.runtime.Symbol;
import com.google.common.collect.Lists;
import com.google.common.collect.Maps;

// Commented by Zhao Chun
// Now we have 2 shift/reduce conflict
// between TIMESTAMP "20100101" and TIMESTAMP "alias"
// between DATE "20100101" and DATE "alias"

parser code {:
    private Symbol errorToken;
    public boolean isVerbose = false;
    public String wild;
    public Expr where;

    // List of expected tokens ids from current parsing state for generating syntax error message
    private final List<Integer> expectedTokenIds = Lists.newArrayList();

    // To avoid reporting trivial tokens as expected tokens in error messages
    private boolean reportExpectedToken(Integer tokenId) {
        if (SqlScanner.isKeyword(tokenId) ||
                tokenId.intValue() == SqlParserSymbols.COMMA ||
                tokenId.intValue() == SqlParserSymbols.IDENT) {
            return true;
        } else {
            return false;
        }
    }

    private String getErrorTypeMessage(int lastTokenId) {
        String msg = null;
        switch(lastTokenId) {
            case SqlParserSymbols.UNMATCHED_STRING_LITERAL:
                msg = "Unmatched string literal";
                break;
            case SqlParserSymbols.NUMERIC_OVERFLOW:
                msg = "Numeric overflow";
                break;
            default:
                msg = "Syntax error";
                break;
        }
        return msg;
    }

    // Override to save error token, just update error information.
    @Override
    public void syntax_error(Symbol token) {
        errorToken = token;

        // derive expected tokens from current parsing state
        expectedTokenIds.clear();
        int state = ((Symbol)stack.peek()).parse_state;
        // get row of actions table corresponding to current parsing state
        // the row consists of pairs of <tokenId, actionId>
        // a pair is stored as row[i] (tokenId) and row[i+1] (actionId)
        // the last pair is a special error action
        short[] row = action_tab[state];
        short tokenId;
        // the expected tokens are all the symbols with a
        // corresponding action from the current parsing state
        for (int i = 0; i < row.length-2; ++i) {
            // Get tokenId and skip actionId
            tokenId = row[i++];
            expectedTokenIds.add(Integer.valueOf(tokenId));
        }
    }

    // Override to keep it from calling report_fatal_error()
    // This exception is not AnalysisException because we don't want this report to client.
    @Override
    public void unrecovered_syntax_error(Symbol cur_token) throws AnalysisException {
        throw new AnalysisException(getErrorTypeMessage(cur_token.sym));
    }


    // Manually throw a parse error on a given symbol for special circumstances.
    public void parseError(String symbolName, int symbolId) throws AnalysisException {
        Symbol errorToken = getSymbolFactory().newSymbol(symbolName, symbolId,
                ((Symbol) stack.peek()), ((Symbol) stack.peek()), null);
        // Call syntax error to gather information about expected tokens, etc.
        // syntax_error does not throw an exception
        syntax_error(errorToken);

        unrecovered_syntax_error(errorToken);
    }

    // Returns error string, consisting of the original
    // stmt with a '^' under the offending token. Assumes
    // that parse() has been called and threw an exception
    public String getErrorMsg(String stmt) {
        if (errorToken == null || stmt == null) {
            return null;
        }
        String[] lines = stmt.split("\n");
        StringBuffer result = new StringBuffer();
        result.append(getErrorTypeMessage(errorToken.sym) + " at:\n");

        // print lines up to and including the one with the error
        for (int i = 0; i < errorToken.left; ++i) {
            result.append(lines[i]);
            result.append('\n');
        }
        // print error indicator
        for (int i = 0; i < errorToken.right - 1; ++i) {
            result.append(' ');
        }
        result.append("^\n");
        // print remaining lines
        for (int i = errorToken.left; i < lines.length; ++i) {
            result.append(lines[i]);
            result.append('\n');
        }

        // only report encountered and expected tokens for syntax errors
        if (errorToken.sym == SqlParserSymbols.UNMATCHED_STRING_LITERAL ||
                errorToken.sym == SqlParserSymbols.NUMERIC_OVERFLOW) {
            return result.toString();
        }

        // append last encountered token
        result.append("Encountered: ");
        String lastToken = SqlScanner.tokenIdMap.get(Integer.valueOf(errorToken.sym));
        if (lastToken != null) {
        	result.append(lastToken);
        } else {
        	result.append("Unknown last token with id: " + errorToken.sym);
        }
        // Append expected tokens
        result.append('\n');
        result.append("Expected: ");
        String expectedToken = null;
        Integer tokenId = null;
        for (int i = 0; i < expectedTokenIds.size(); ++i) {
            tokenId = expectedTokenIds.get(i);
             // keywords hints
            if (SqlScanner.isKeyword(lastToken) && tokenId.intValue() == SqlParserSymbols.IDENT) {
            	result.append(String.format("%s is keyword, maybe `%s`", lastToken, lastToken) + ", ");
            	continue;
            }

			if (reportExpectedToken(tokenId)) {
                expectedToken = SqlScanner.tokenIdMap.get(tokenId);
                result.append(expectedToken + ", ");
            }
        }
        // remove trailing ", "
        result.delete(result.length()-2, result.length());
        result.append('\n');

        return result.toString();
    }
:};

// Total keywords of palo
terminal String KW_ADD, KW_AFTER, KW_AGGREGATE, KW_ALL, KW_ALTER, KW_AND, KW_ANTI, KW_AS, KW_ASC, KW_AUTHORS, 
    KW_BACKEND, KW_BACKUP, KW_BETWEEN, KW_BEGIN, KW_BIGINT, KW_BOOLEAN, KW_BOTH, KW_BROKER, KW_BACKENDS, KW_BY,
    KW_CANCEL, KW_CASE, KW_CAST, KW_CHAIN, KW_CHAR, KW_CHARSET, KW_SYSTEM, KW_CLUSTER, KW_CLUSTERS, KW_LINK, KW_MIGRATE, KW_MIGRATIONS, KW_ENTER,
    KW_COLLATE, KW_COLLATION, KW_COLUMN, KW_COLUMNS, KW_COMMENT, KW_COMMIT, KW_COMMITTED,
    KW_CONNECTION, KW_CONNECTION_ID, KW_CONSISTENT, KW_COUNT, KW_CREATE, KW_CROSS, KW_CURRENT, KW_CURRENT_USER,
    KW_DATA, KW_DATABASE, KW_DATABASES, KW_DATE, KW_DATETIME, KW_DECIMAL, KW_DECOMMISSION, KW_DEFAULT, KW_DESC, KW_DESCRIBE,
    KW_DELETE, KW_DISTINCT, KW_DISTINCTPC, KW_DISTINCTPCSA, KW_DISTRIBUTED, KW_BUCKETS, KW_DIV, KW_DOUBLE, KW_DROP, KW_DUPLICATE,
    KW_ELSE, KW_END, KW_ENGINE, KW_ENGINES, KW_ERRORS, KW_EVENTS, KW_EXISTS, KW_EXPORT, KW_EXTERNAL, KW_EXTRACT,
    KW_FALSE, KW_FOLLOWER, KW_FOLLOWING, KW_FROM, KW_FIRST, KW_FLOAT, KW_FOR, KW_FULL, KW_FUNCTION,
    KW_GLOBAL, KW_GRANT, KW_GROUP,
    KW_HASH, KW_HAVING, KW_HELP,KW_HLL, KW_HLL_UNION,
    KW_IDENTIFIED, KW_IF, KW_IN, KW_INDEX, KW_INDEXES, KW_INFILE,
    KW_INNER, KW_INSERT, KW_INT, KW_INTERVAL, KW_INTO, KW_IS, KW_ISNULL,  KW_ISOLATION,
    KW_JOIN,
    KW_KEY, KW_KILL,
    KW_LABEL, KW_LARGEINT, KW_LEFT, KW_LESS, KW_LEVEL, KW_LIKE, KW_LIMIT, KW_LOAD, KW_LOCAL,
    KW_MAX, KW_MAX_VALUE, KW_MERGE, KW_MIN, KW_MODIFY,
    KW_NAME, KW_NAMES, KW_NEGATIVE, KW_NO, KW_NOT, KW_NULL,
    KW_OBSERVER, KW_OFFSET, KW_ON, KW_ONLY, KW_OPEN, KW_OR, KW_ORDER, KW_OUTER, KW_OVER,
    KW_PARTITION, KW_PARTITIONS, KW_PRECEDING,
    KW_PASSWORD, KW_PLUGIN, KW_PLUGINS,
    KW_PRIMARY,
    KW_PROC, KW_PROCEDURE, KW_PROCESSLIST, KW_PROPERTIES, KW_PROPERTY,
    KW_QUERY, KW_QUOTA,
    KW_RANDOM, KW_RANGE, KW_READ, KW_RECOVER, KW_REGEXP, KW_RELEASE, KW_RENAME,
    KW_REPEATABLE, KW_REPLACE, KW_RESOURCE, KW_RESTORE, KW_REVOKE,
    KW_RIGHT, KW_ROLLBACK, KW_ROLLUP, KW_ROW, KW_ROWS,
    KW_SELECT, KW_SEMI, KW_SERIALIZABLE, KW_SESSION, KW_SET, KW_SHOW,
    KW_SMALLINT, KW_SNAPSHOT, KW_SONAME, KW_SPLIT, KW_START, KW_STATUS, KW_STORAGE, KW_STRING, 
    KW_SUM, KW_SUPERUSER, KW_SYNC,
    KW_TABLE, KW_TABLES, KW_TABLET, KW_TERMINATED, KW_THAN, KW_THEN, KW_TIMESTAMP, KW_TINYINT,
    KW_TO, KW_TRANSACTION, KW_TRIGGERS, KW_TRIM, KW_TRUE, KW_TYPES,
    KW_UNCOMMITTED, KW_UNBOUNDED, KW_UNION, KW_UNIQUE, KW_UNSIGNED, KW_USE, KW_USER, KW_USING,
    KW_VALUES, KW_VARCHAR, KW_VARIABLES, KW_VIEW,
    KW_WARNINGS, KW_WHEN, KW_WHITELIST, KW_WHERE, KW_WITH, KW_WORK, KW_WRITE;

terminal COMMA, DOT, AT, STAR, LPAREN, RPAREN, SEMICOLON, LBRACKET, RBRACKET, DIVIDE, MOD, ADD, SUBTRACT;
terminal BITAND, BITOR, BITXOR, BITNOT;
terminal EQUAL, NOT, LESSTHAN, GREATERTHAN, SET_VAR;
terminal String IDENT;
terminal String NUMERIC_OVERFLOW;
terminal Long INTEGER_LITERAL;
terminal String LARGE_INTEGER_LITERAL;
terminal Double FLOATINGPOINT_LITERAL;
terminal BigDecimal DECIMAL_LITERAL;
terminal String STRING_LITERAL;
terminal String UNMATCHED_STRING_LITERAL;
terminal String COMMENTED_PLAN_HINTS;

// Statement that the result of this parser.
nonterminal StatementBase query, stmt, show_stmt, show_param, help_stmt, load_stmt, describe_stmt, alter_stmt,
    use_stmt, kill_stmt, drop_stmt, recover_stmt, grant_stmt, revoke_stmt, create_stmt, set_stmt, sync_stmt, cancel_stmt, cancel_param, delete_stmt,
    link_stmt, migrate_stmt, enter_stmt, unsupported_stmt, export_stmt;

// unsupported statement
nonterminal opt_with_consistent_snapshot, opt_work, opt_chain, opt_release;

// Single select statement.
nonterminal SelectStmt select_stmt;

// No return.
nonterminal describe_command, opt_full, opt_inner, opt_outer, from_or_in, keys_or_index, opt_storage, opt_wild_where,
            charset, equal, transaction_characteristics, isolation_level,
            transaction_access_mode, isolation_types;

// String
nonterminal String user, opt_user;

// Description of user
nonterminal UserDesc grant_user;

// Select or union statement.
nonterminal QueryStmt query_stmt;
// Single select_stmt or parenthesized query_stmt.
nonterminal QueryStmt union_operand;
// List of select or union blocks connected by UNION operators or a single select block.
nonterminal List<UnionOperand> union_operand_list;
// List of select blocks connected by UNION operators, with order by or limit.
nonterminal QueryStmt union_with_order_by_or_limit;
nonterminal InsertStmt insert_stmt;
nonterminal InsertTarget insert_target;
nonterminal InsertSource insert_source;

nonterminal BackupStmt backup_stmt;
nonterminal RestoreStmt restore_stmt;

nonterminal SelectList select_clause, select_list, select_sublist;
nonterminal SelectListItem select_list_item, star_expr;
nonterminal Expr expr, non_pred_expr, arithmetic_expr, timestamp_arithmetic_expr;
nonterminal LiteralExpr set_expr_or_default;
nonterminal ArrayList<Expr> expr_list;
nonterminal ArrayList<Expr> func_arg_list;
nonterminal String select_alias, opt_table_alias;
nonterminal ArrayList<String> ident_list, opt_using_partition;
nonterminal ClusterName cluster_name;
nonterminal ClusterName des_cluster_name;
nonterminal TableName table_name;
nonterminal FunctionName function_name;
nonterminal Expr where_clause;
nonterminal Predicate predicate, between_predicate, comparison_predicate,
  compound_predicate, in_predicate, like_predicate, exists_predicate;
nonterminal ArrayList<Expr> group_by_clause, opt_partition_by_clause;
nonterminal Expr having_clause;
nonterminal ArrayList<OrderByElement> order_by_elements, order_by_clause;
nonterminal OrderByElement order_by_element;
nonterminal LimitElement limit_clause;
nonterminal Expr cast_expr, case_else_clause, analytic_expr;
nonterminal LiteralExpr literal;
nonterminal CaseExpr case_expr;
nonterminal ArrayList<CaseWhenClause> case_when_clause_list;
nonterminal FunctionParams function_params;
nonterminal Expr function_call_expr;
nonterminal AnalyticWindow opt_window_clause;
nonterminal AnalyticWindow.Type window_type;
nonterminal AnalyticWindow.Boundary window_boundary;
nonterminal SlotRef column_ref;
nonterminal ArrayList<TableRef> table_ref_list;
nonterminal FromClause from_clause;
nonterminal TableRef table_ref;
nonterminal TableRef base_table_ref;
nonterminal WithClause opt_with_clause;
nonterminal ArrayList<View> with_view_def_list;
nonterminal View with_view_def;
nonterminal Subquery subquery;
nonterminal InlineViewRef inline_view_ref;
nonterminal JoinOperator join_operator;
nonterminal ArrayList<String> opt_plan_hints;
nonterminal ArrayList<String> opt_sort_hints;
nonterminal PrimitiveType primitive_type;
nonterminal Expr sign_chain_expr;
nonterminal Qualifier union_op;

nonterminal ArrayList<PartitionName> opt_partition_name_list, partition_name_list;
nonterminal PartitionName partition_name;

// Set type
nonterminal SetType option_type, opt_var_type, var_ident_type;

// Set variable
nonterminal SetVar option_value, option_value_follow_option_type, option_value_no_option_type,
        user_property;

// List of set variable
nonterminal List<SetVar> option_value_list, option_value_list_continued, start_option_value_list,
        start_option_value_list_following_option_type, user_property_list;

nonterminal Map<String, String> key_value_map, opt_key_value_map, opt_properties, opt_ext_properties;
nonterminal Column column_definition;
nonterminal ArrayList<Column> column_definition_list;
nonterminal ColumnType column_type;
nonterminal List<ColumnType> column_type_list;
nonterminal AggregateType opt_agg_type;
nonterminal PartitionDesc opt_partition;
nonterminal DistributionDesc opt_distribution;
nonterminal Integer opt_distribution_number;
nonterminal KeysDesc opt_keys;

nonterminal PartitionKeyDesc partition_key_desc;
nonterminal SingleRangePartitionDesc single_range_partition_desc;
nonterminal List<SingleRangePartitionDesc> opt_single_range_partition_desc_list;
nonterminal List<SingleRangePartitionDesc> single_range_partition_desc_list;

nonterminal List<AccessPrivilege> privilege_list;
nonterminal List<String> string_list;
nonterminal List<Long> integer_list;
nonterminal AccessPrivilege privilege_type;

nonterminal DataDescription data_desc;
nonterminal List<DataDescription> data_desc_list;
nonterminal LabelName job_label;
nonterminal String opt_system;
nonterminal String opt_cluster;
nonterminal BrokerDesc opt_broker;
nonterminal List<String> opt_col_list, opt_dup_keys;
nonterminal List<String> opt_partitions;
nonterminal List<Expr> opt_col_mapping_list;
nonterminal ColumnSeparator opt_field_term;

// Boolean
nonterminal Boolean opt_negative, opt_super_user, opt_is_allow_null, opt_is_key;
nonterminal String opt_from_rollup, opt_to_rollup;
nonterminal ColumnPosition opt_col_pos;

// Alter statement
nonterminal AlterClause alter_system_clause, alter_cluster_clause, alter_table_clause, alter_user_clause;
nonterminal List<AlterClause> alter_table_clause_list;

//
nonterminal String keyword, ident, ident_or_text, variable_name, text_or_password,
        charset_name_or_default, old_or_new_charset_name_or_default, opt_collate,
        collation_name_or_default;

nonterminal String opt_db, opt_partition_name, procedure_or_function, opt_default_value, opt_comment, opt_engine;
nonterminal Boolean opt_if_exists, opt_if_not_exists;
nonterminal Boolean opt_external;

nonterminal ShowAlterStmt.AlterType opt_alter_type;

precedence left KW_FULL, KW_MERGE;
precedence left DOT;
precedence left SET_VAR;
precedence left KW_OR;
precedence left KW_AND;
precedence left KW_NOT, NOT;
precedence left KW_BETWEEN, KW_IN, KW_IS, KW_EXISTS;
precedence left KW_LIKE, KW_REGEXP;
precedence left EQUAL, LESSTHAN, GREATERTHAN;
precedence left ADD, SUBTRACT;
precedence left AT, STAR, DIVIDE, MOD, KW_DIV;
precedence left BITAND, BITOR, BITXOR, BITNOT;
precedence left KW_ORDER, KW_BY, KW_LIMIT;
precedence left LPAREN, RPAREN;
// Support chaining of timestamp arithmetic exprs.
precedence left KW_INTERVAL;
precedence left KW_OVER;
start with query;

query ::=
    stmt:stmt
    {:
        RESULT = stmt;
    :}
    | stmt:stmt SEMICOLON
    {:
        RESULT = stmt;
    :}
    ;

stmt ::=
     alter_stmt:stmt
    {: RESULT = stmt; :}
    | create_stmt:query
    {: RESULT = query; :}
    | link_stmt:query
    {: RESULT = query; :}
    | migrate_stmt:query
    {: RESULT = query; :}
    | enter_stmt:enter
    {: RESULT = enter; :}
    | query_stmt:query
    {: RESULT = query; :}
    | drop_stmt:stmt
    {: RESULT = stmt; :}
    | recover_stmt:stmt
    {: RESULT = stmt; :}
    | use_stmt:use
    {: RESULT = use; :}
    | set_stmt:set
    {: RESULT = set; :}
    | kill_stmt:kill
    {: RESULT = kill; :}
    | describe_stmt:describe
    {: RESULT = describe; :}
    | show_stmt:show
    {: RESULT = show; :}
    | grant_stmt:grant
    {: RESULT = grant; :}
    | revoke_stmt:revoke
    {: RESULT = revoke; :}
    | help_stmt : stmt
    {: RESULT = stmt; :}
    | load_stmt : stmt
    {: RESULT = stmt; :}
    | cancel_stmt : stmt
    {: RESULT = stmt; :}
    | delete_stmt : stmt
    {: RESULT = stmt; :}
    | sync_stmt : stmt
    {: RESULT = stmt; :}
    | insert_stmt : stmt
    {: RESULT = stmt; :}
    | backup_stmt : stmt
    {: RESULT = stmt; :}
	| restore_stmt : stmt
    {: RESULT = stmt; :}
    | unsupported_stmt : stmt
    {: RESULT = stmt; :}
    | export_stmt : stmt
    {: RESULT = stmt; :}
    | /* empty: query only has comments */
    {:
        RESULT = new EmptyStmt();
    :}
    ;

cluster_name ::=
    ident:cluster
    {:
        RESULT = new ClusterName(cluster, "");
	:}
    | ident:cluster DOT ident:db
    {:   
        RESULT = new ClusterName(cluster, db);
    :}   
    ;

des_cluster_name ::=
    ident:cluster
    {:   
        RESULT = new ClusterName(cluster, ""); 
    :}   
    | ident:cluster DOT ident:db
    {:   
        RESULT = new ClusterName(cluster, db); 
    :}   
    ;

// link statement
link_stmt ::=
    KW_LINK KW_DATABASE cluster_name:src_name des_cluster_name:des_name
    {:
        RESULT = new LinkDbStmt(src_name, des_name);
    :}
    ;

// migrate statement
migrate_stmt ::=
    KW_MIGRATE KW_DATABASE cluster_name:src_name des_cluster_name:des_name
    {:
        RESULT = new MigrateDbStmt(src_name, des_name);
    :}
    ;

// Alter Statement
alter_stmt ::=
    KW_ALTER KW_TABLE table_name:tbl
    alter_table_clause_list:clauses
    {:
        RESULT = new AlterTableStmt(tbl, clauses);
    :}
    | KW_ALTER KW_SYSTEM alter_system_clause:clause
    {:
        RESULT = new AlterSystemStmt(clause);
    :}
    | KW_ALTER KW_CLUSTER ident:name opt_properties:properties 
    {:
        RESULT = new AlterClusterStmt(name, properties);
    :}
    | KW_ALTER KW_DATABASE ident:dbName KW_SET KW_DATA KW_QUOTA INTEGER_LITERAL:quota
    {:
        RESULT = new AlterDatabaseQuotaStmt(dbName, quota);
    :}
    | KW_ALTER KW_DATABASE ident:dbName KW_RENAME ident:newDbName
    {:
        RESULT = new AlterDatabaseRename(dbName, newDbName);
    :}
    | KW_ALTER KW_USER ident:userName alter_user_clause:clause
    {:
        RESULT = new AlterUserStmt(userName, clause);
	:}
    ;

opt_user ::=
    /* empty */
    | KW_FOR user:user

    {:
        RESULT = user;

    :}
    ;
alter_table_clause_list ::=
    alter_table_clause:clause
    {:
        RESULT = Lists.newArrayList(clause);
    :}
    | alter_table_clause_list:list COMMA alter_table_clause:clause
    {:
        list.add(clause);
        RESULT = list;
    :}
    ;

opt_to_rollup ::=
    {:
        RESULT = null;
    :}
    | KW_TO ident:rollup
    {:
        RESULT = rollup;
    :}
    | KW_IN ident:rollup
    {:
        RESULT = rollup;
    :}
    ;

opt_from_rollup ::=
    {:
        RESULT = null;
    :}
    | KW_FROM ident:rollup
    {:
        RESULT = rollup;
    :}
    ;

opt_col_pos ::=
    {:
        RESULT = null;
    :}
    | KW_FIRST
    {:
        RESULT = ColumnPosition.FIRST;
    :}
    | KW_AFTER ident:col
    {:
        RESULT = new ColumnPosition(col);
    :}
    ;

opt_dup_keys ::=
    {:
        RESULT = null;
    :}
    | KW_DUPLICATE KW_KEY LPAREN ident_list:cols RPAREN
    {:
        RESULT = cols;
    :}
    ;
	
alter_table_clause ::=
    KW_ADD KW_COLUMN column_definition:col opt_col_pos:col_pos opt_to_rollup:rollup opt_properties:properties
    {:
        RESULT = new AddColumnClause(col, col_pos, rollup, properties);
    :}
    | KW_ADD KW_COLUMN LPAREN column_definition_list:cols RPAREN opt_to_rollup:rollup opt_properties:properties
    {:
        RESULT = new AddColumnsClause(cols, rollup, properties);
    :}
    | KW_ADD KW_ROLLUP ident:rollupName LPAREN ident_list:cols RPAREN opt_dup_keys:dup_keys opt_from_rollup:baseRollup opt_properties:properties
    {:
        RESULT = new AddRollupClause(rollupName, cols, dup_keys, baseRollup, properties);
    :}
    | KW_DROP KW_COLUMN ident:col opt_from_rollup:rollup opt_properties:properties
    {:
        RESULT = new DropColumnClause(col, rollup, properties);
    :}
    | KW_DROP KW_ROLLUP ident:rollup opt_properties:properties
    {:
        RESULT = new DropRollupClause(rollup, properties);
    :}
    | KW_MODIFY KW_COLUMN column_definition:col opt_col_pos:col_pos opt_from_rollup:rollup opt_properties:properties
    {:
        RESULT = new ModifyColumnClause(col, col_pos, rollup, properties);
    :}
    | KW_ORDER KW_BY LPAREN ident_list:cols RPAREN opt_from_rollup:rollup opt_properties:properties
    {:
        RESULT = new ReorderColumnsClause(cols, rollup, properties);
    :}
    | opt_properties:properties
    {:
        RESULT = new ModifyTablePropertiesClause(properties);
    :}
    | KW_ADD single_range_partition_desc:desc opt_distribution:distribution opt_properties:properties
    {:
        RESULT = new AddPartitionClause(desc, distribution, properties);
    :}
    | KW_DROP KW_PARTITION opt_if_exists:ifExists ident:partitionName
    {:
        RESULT = new DropPartitionClause(ifExists, partitionName);
    :}
    | KW_MODIFY KW_PARTITION ident:partitionName KW_SET LPAREN key_value_map:properties RPAREN
    {:
        RESULT = new ModifyPartitionClause(partitionName, properties);
    :}
    | KW_RENAME ident:newTableName
    {:
        RESULT = new TableRenameClause(newTableName);
    :}
    | KW_RENAME KW_ROLLUP ident:rollupName ident:newRollupName
    {:
        RESULT = new RollupRenameClause(rollupName, newRollupName);
    :}
    | KW_RENAME KW_PARTITION ident:partitionName ident:newPartitionName
    {:
        RESULT = new PartitionRenameClause(partitionName, newPartitionName);
    :}
    | KW_RENAME KW_COLUMN ident:colName ident:newColName
    {:
        RESULT = new ColumnRenameClause(colName, newColName);
    :}
    ;

alter_system_clause ::=
    KW_ADD KW_BACKEND string_list:hostPorts
    {:
        RESULT = new AddBackendClause(hostPorts);
    :}
    | KW_DROP KW_BACKEND string_list:hostPorts
    {:
        RESULT = new DropBackendClause(hostPorts);
    :}
    | KW_DECOMMISSION KW_BACKEND string_list:hostPorts
    {:
        RESULT = new DecommissionBackendClause(hostPorts);
    :}
    | KW_ADD KW_OBSERVER STRING_LITERAL:hostPort
    {:
        RESULT = new AddObserverClause(hostPort);
    :}
    | KW_DROP KW_OBSERVER STRING_LITERAL:hostPort
    {:
        RESULT = new DropObserverClause(hostPort);
    :}
    | KW_ADD KW_FOLLOWER STRING_LITERAL:hostPort
    {:
        RESULT = new AddFollowerClause(hostPort);
    :}
    | KW_DROP KW_FOLLOWER STRING_LITERAL:hostPort
    {:
        RESULT = new DropFollowerClause(hostPort);
    :}
    /* Broker manipulation */
    | KW_ADD KW_BROKER ident_or_text:brokerName string_list:hostPorts
    {:
        RESULT = ModifyBrokerClause.createAddBrokerClause(brokerName, hostPorts);
    :}
    | KW_DROP KW_BROKER ident_or_text:brokerName string_list:hostPorts
    {:
        RESULT = ModifyBrokerClause.createDropBrokerClause(brokerName, hostPorts);
    :}
    | KW_DROP KW_ALL KW_BROKER ident_or_text:brokerName 
    {:
        RESULT = ModifyBrokerClause.createDropAllBrokerClause(brokerName);
    :}
    // set load error url
    | KW_SET ident equal STRING_LITERAL:url
    {:
        RESULT = new AlterLoadErrorUrlClause(url);
        // RESULT = new Object();
    :}
    ;

alter_cluster_clause ::=
    KW_MODIFY opt_properties:properties
    {:
        RESULT = new AlterClusterClause(AlterClusterType.ALTER_CLUSTER_PROPERTIES, properties);
    :}
    ;
alter_user_clause ::=
	KW_ADD KW_WHITELIST string_list:hostPorts
	{:
		RESULT = new AlterUserClause(AlterUserType.ADD_USER_WHITELIST, hostPorts);
	:}
	| KW_DELETE KW_WHITELIST string_list:hostPorts
	{:
		RESULT = new AlterUserClause(AlterUserType.DELETE_USER_WHITELIST, hostPorts);
	:}
	;

// Sync Stmt
sync_stmt ::=
    KW_SYNC
    {:
        RESULT = new SyncStmt();
    :}
    ;

// Create Statement
create_stmt ::=
    /* Database */
    KW_CREATE KW_DATABASE opt_if_not_exists:ifNotExists ident:db
    {:
        RESULT = new CreateDbStmt(ifNotExists, db);
    :}
    /* cluster */
   /* KW_CREATE KW_CLUSTER ident:name  opt_properties:properties KW_IDENTIFIED KW_BY STRING_LITERAL:password
    {:
        RESULT = new CreateClusterStmt(name, properties, password);
    :}*/
    /* Function */
    | KW_CREATE KW_FUNCTION function_name:functionName LPAREN column_type_list:arguments RPAREN
            column_type:retrunType KW_SONAME STRING_LITERAL:soPath
            opt_properties:properties
    {:
        RESULT = new CreateFunctionStmt(functionName, arguments, retrunType, soPath, properties, false);
    :}
    | KW_CREATE KW_AGGREGATE KW_FUNCTION function_name:functionName LPAREN column_type_list:arguments RPAREN
            column_type:retrunType KW_SONAME STRING_LITERAL:soPath
            opt_properties:properties
    {:
        RESULT = new CreateFunctionStmt(functionName, arguments, retrunType, soPath, properties, true);
    :}
    /* Table */
    | KW_CREATE opt_external:isExternal KW_TABLE opt_if_not_exists:ifNotExists table_name:name
            LPAREN column_definition_list:columns RPAREN opt_engine:engineName
            opt_keys:keys
            opt_partition:partition
            opt_distribution:distribution
            opt_properties:tblProperties
            opt_ext_properties:extProperties
    {:
        RESULT = new CreateTableStmt(ifNotExists, isExternal, name, columns, engineName, keys, partition, distribution, tblProperties, extProperties);
    :}
    /* User */
    | KW_CREATE KW_USER grant_user:user opt_super_user:isSuperuser
    {:
        RESULT = new CreateUserStmt(user, isSuperuser);
    :}
    | KW_CREATE KW_VIEW opt_if_not_exists:ifNotExists table_name:viewName
        opt_col_list:columns KW_AS query_stmt:view_def
    {:
        RESULT = new CreateViewStmt(ifNotExists, viewName, columns, view_def);
    :}
    /* cluster */
    | KW_CREATE KW_CLUSTER ident:name opt_properties:properties KW_IDENTIFIED KW_BY STRING_LITERAL:password
    {:
        RESULT = new CreateClusterStmt(name, properties, password);
    :}
    ;

grant_user ::=
    user:user
    {:
        /* No password */
        RESULT = new UserDesc(user);
    :}
    | user:user KW_IDENTIFIED KW_BY STRING_LITERAL:password
    {:
        /* plain text password */
        RESULT = new UserDesc(user, password, true);
    :}
    | user:user KW_IDENTIFIED KW_BY KW_PASSWORD STRING_LITERAL:password
    {:
        /* hashed password */
        RESULT = new UserDesc(user, password, false);
    :}
    ;

opt_super_user ::=
    /* Empty */
    {:
        RESULT = false;
    :}
    | KW_SUPERUSER
    {:
        RESULT = true;
    :}
    ;

user ::=
    ident_or_text:user
    {:
        RESULT = user;
    :}
    ;

column_type_list ::=
    column_type:type
    {:
    RESULT = Lists.newArrayList();
    RESULT.add(type);
    :}
    | column_type_list:types COMMA column_type:type
    {:
    types.add(type);
    RESULT = types;
    :}
    ;

// Help statement
help_stmt ::=
    KW_HELP ident_or_text:mark
    {:
        RESULT = new HelpStmt(mark);
    :}
    ;

// Export statement
export_stmt ::=
    // KW_EXPORT KW_TABLE table_name:tblName opt_using_partition:partitions 
    KW_EXPORT KW_TABLE base_table_ref:tblRef
    KW_TO STRING_LITERAL:path
    opt_properties:properties
    opt_broker:broker
    {:
        // RESULT = new ExportStmt(tblName, partitions, path, properties, broker);
        RESULT = new ExportStmt(tblRef, path, properties, broker);
    :}
    ;

// Load
load_stmt ::=
    KW_LOAD KW_LABEL job_label:label
    LPAREN data_desc_list:dataDescList RPAREN
    opt_broker:broker
    opt_system:system
    opt_properties:properties
    {:
        RESULT = new LoadStmt(label, dataDescList, broker, system, properties);
    :}
    ;

job_label ::=
    ident:label
    {:
        RESULT = new LabelName("", label);
    :}
    | ident:db DOT ident:label
    {:
        RESULT = new LabelName(db, label);
    :}
    ;

data_desc_list ::=
    data_desc:desc
    {:
        RESULT = Lists.newArrayList(desc);
    :}
    | data_desc_list:list COMMA data_desc:desc
    {:
        list.add(desc);
        RESULT = list;
    :}
    ;

data_desc ::=
    KW_DATA KW_INFILE LPAREN string_list:files RPAREN
    opt_negative:isNeg
    KW_INTO KW_TABLE ident:tableName
    opt_partitions:partitionNames
    opt_field_term:colSep
    opt_col_list:colList
    opt_col_mapping_list:colMappingList
    {:
        RESULT = new DataDescription(tableName, partitionNames, files, colList, colSep, isNeg, colMappingList);
    :}
    ;

opt_partitions ::=
    /* Empty */
    {:
        RESULT = null;
    :}
    | KW_PARTITION LPAREN ident_list:partitionNames RPAREN
    {:
        RESULT = partitionNames;
    :}
    ;

opt_negative ::=
    {:
        RESULT = false;
    :}
    | KW_NEGATIVE
    {:
        RESULT = true;
    :}
    ;

opt_field_term ::=
    /* Empty */
    {:
        RESULT = null;
    :}
    | KW_COLUMNS KW_TERMINATED KW_BY STRING_LITERAL:sep
    {:
        RESULT = new ColumnSeparator(sep);
    :}
    ;

opt_col_list ::=
    {:
        RESULT = null;
    :}
    | LPAREN ident_list:colList RPAREN
    {:
        RESULT = colList;
    :}
    ;

opt_col_mapping_list ::=
    /* Empty */
    {:
        RESULT = null;
    :}
    | KW_SET LPAREN expr_list:list RPAREN
    {:
    	RESULT = list;
    :}
    ;

opt_system ::=
    {:
        RESULT = null;
    :}
    | KW_BY ident_or_text:system
    {:
        RESULT = system;
    :}
    ;

opt_broker ::=
    {:
        RESULT = null;
    :}
    | KW_WITH KW_BROKER ident_or_text:name
    {:
        RESULT = new BrokerDesc(name, null);
    :}
    | KW_WITH KW_BROKER ident_or_text:name LPAREN key_value_map:properties RPAREN
    {:
        RESULT = new BrokerDesc(name, properties);
    :}
    ;

opt_cluster ::=
    {:
        RESULT = null;
    :}
    | KW_BY ident_or_text:cluster
    {:
        RESULT = cluster;
    :}
    ;

// Grant statement
grant_stmt ::=
    KW_GRANT privilege_list:privs KW_ON ident:dbName KW_TO user:user
    {:
        RESULT = new GrantStmt(user, dbName, privs);
    :}
    ;

// Revoke statement
revoke_stmt ::=
    /* for now, simply revoke ALL privilege */
    KW_REVOKE KW_ALL KW_ON ident:dbName KW_FROM user:user
    {:
        RESULT = new RevokeStmt(user, dbName);
    :}
    ;

// Drop statement
drop_stmt ::=
    /* Database */
    KW_DROP KW_DATABASE opt_if_exists:ifExists ident:db
    {:
        RESULT = new DropDbStmt(ifExists, db);
    :}
    /* cluster */
    | KW_DROP KW_CLUSTER opt_if_exists:ifExists ident:cluster
    {:
        RESULT = new DropClusterStmt(ifExists, cluster);
    :}
    /* Function */
    | KW_DROP KW_FUNCTION function_name:functionName
    {:
        RESULT = new DropFunctionStmt(functionName);
    :}
    /* Table */
    | KW_DROP KW_TABLE opt_if_exists:ifExists table_name:name
    {:
        RESULT = new DropTableStmt(ifExists, name);
    :}
    /* User */
    | KW_DROP KW_USER STRING_LITERAL:user
    {:
        RESULT = new DropUserStmt(user);
    :}
    /* View */
    | KW_DROP KW_VIEW opt_if_exists:ifExists table_name:name
    {:
        RESULT = new DropTableStmt(ifExists, name, true);
    :}
    ;

// Recover statement
recover_stmt ::=
    KW_RECOVER KW_DATABASE ident:dbName
    {:
        RESULT = new RecoverDbStmt(dbName);
    :}
    | KW_RECOVER KW_TABLE table_name:dbTblName
    {:
        RESULT = new RecoverTableStmt(dbTblName);
    :}
    | KW_RECOVER KW_PARTITION ident:partitionName KW_FROM table_name:dbTblName
    {:
        RESULT = new RecoverPartitionStmt(dbTblName, partitionName);
    :}
    ;

opt_agg_type ::=
    {: RESULT = null; :}
    | KW_SUM
    {:
    RESULT = AggregateType.SUM;
    :}
    | KW_MAX
    {:
    RESULT = AggregateType.MAX;
    :}
    | KW_MIN
    {:
    RESULT = AggregateType.MIN;
    :}
    | KW_REPLACE
    {:
    RESULT = AggregateType.REPLACE;
    :}
    | KW_HLL_UNION
    {:
    RESULT = AggregateType.HLL_UNION;
    :}
    ;

opt_partition ::=
    /* Empty: no partition */
    {:
        RESULT = null;
    :}
    /* Range partition */
    | KW_PARTITION KW_BY KW_RANGE LPAREN ident_list:columns RPAREN
            LPAREN opt_single_range_partition_desc_list:list RPAREN
    {:
        RESULT = new RangePartitionDesc(columns, list);
    :}
    ;

opt_distribution ::=
    /* Empty: no distributed */
    {:
        RESULT = null;
    :}
    /* Hash distributed */
    | KW_DISTRIBUTED KW_BY KW_HASH LPAREN ident_list:columns RPAREN opt_distribution_number:numDistribution
    {:
        RESULT = new HashDistributionDesc(numDistribution, columns);
    :}
    /* Random distributed */
    | KW_DISTRIBUTED KW_BY KW_RANDOM opt_distribution_number:numDistribution
    {:
        RESULT = new RandomDistributionDesc(numDistribution);
    :}
    ;

opt_distribution_number ::=
    /* Empty */
    {:
        /* If distribution number is null, default distribution number is 10. */
        RESULT = 10;
    :}
    | KW_BUCKETS INTEGER_LITERAL:numDistribution
    {:
        RESULT = numDistribution.intValue();
    :}
    ;

opt_keys ::=
    /* Empty */
    {:
        RESULT = null;
    :}
    /* primary_keys */
    | KW_PRIMARY KW_KEY LPAREN ident_list:keys RPAREN
    {:
        RESULT = new KeysDesc(KeysType.PRIMARY_KEYS, keys);
    :}
    /* dup_keys */
    | KW_DUPLICATE KW_KEY LPAREN ident_list:keys RPAREN
    {:
        RESULT = new KeysDesc(KeysType.DUP_KEYS, keys);
    :}
    /* unique_keys */
    | KW_UNIQUE KW_KEY LPAREN ident_list:keys RPAREN
    {:
        RESULT = new KeysDesc(KeysType.UNIQUE_KEYS, keys);
    :}
    /* agg_keys */
    | KW_AGGREGATE KW_KEY LPAREN ident_list:keys RPAREN
    {:
        RESULT = new KeysDesc(KeysType.AGG_KEYS, keys);
    :}
    ;

opt_single_range_partition_desc_list ::=
	/* Empty */
    {:
        RESULT = null;
    :}
	| single_range_partition_desc_list:list
	{:
		RESULT = list;
	:}
	;

single_range_partition_desc_list ::=
    single_range_partition_desc_list:list COMMA single_range_partition_desc:desc
    {:
        list.add(desc);
        RESULT = list;
    :}
    | single_range_partition_desc:desc
    {:
        RESULT = Lists.newArrayList(desc);
    :}
    ;

single_range_partition_desc ::=
    KW_PARTITION opt_if_not_exists:ifNotExists ident:partName KW_VALUES KW_LESS KW_THAN partition_key_desc:desc
        opt_key_value_map:properties
    {:
        RESULT = new SingleRangePartitionDesc(ifNotExists, partName, desc, properties);
    :}
    ;

partition_key_desc ::=
    KW_MAX_VALUE
    {:
        RESULT = PartitionKeyDesc.createMaxKeyDesc();
    :}
    | LPAREN string_list:keys RPAREN
    {:
        RESULT = new PartitionKeyDesc(keys);
    :}
    ;

opt_engine ::=
    {: RESULT = null; :}
    | KW_ENGINE EQUAL ident:engineName
    {: RESULT = engineName; :}
    ;

opt_key_value_map ::=
    {:
    RESULT = null;
    :}
    | LPAREN key_value_map:map RPAREN
    {:
    RESULT = map;
    :}
    ;

key_value_map ::=
    STRING_LITERAL:name EQUAL STRING_LITERAL:value
    {:
    RESULT = Maps.newHashMap();
    RESULT.put(name, value);
    :}
    | key_value_map:map COMMA STRING_LITERAL:name EQUAL STRING_LITERAL:value
    {:
    map.put(name, value);
    RESULT = map;
    :}
    ;

opt_properties ::=
    {:
    RESULT = null;
    :}
    | KW_PROPERTIES LPAREN key_value_map:map RPAREN
    {:
    RESULT = map;
    :}
    ;
    
opt_ext_properties ::=
    {:
    RESULT = null;
    :}
    | KW_BROKER KW_PROPERTIES LPAREN key_value_map:map RPAREN
    {:
    RESULT = map;
    :}
    ;

column_definition_list ::=
    column_definition:column
    {:
    RESULT = Lists.newArrayList();
    RESULT.add(column);
    :}
    | column_definition_list:list COMMA column_definition:column
    {:
    list.add(column);
    RESULT = list;
    :}
    ;

column_type ::=
    KW_TINYINT
    {:
        RESULT = ColumnType.createType(PrimitiveType.TINYINT);
    :}
    | KW_TINYINT LPAREN INTEGER_LITERAL:length RPAREN
    {:
        RESULT = ColumnType.createType(PrimitiveType.TINYINT);
    :}
    | KW_SMALLINT
    {:
        RESULT = ColumnType.createType(PrimitiveType.SMALLINT);
    :}
    | KW_SMALLINT LPAREN INTEGER_LITERAL:length RPAREN
    {:
        RESULT = ColumnType.createType(PrimitiveType.SMALLINT);
    :}
    | KW_INT
    {:
        RESULT = ColumnType.createType(PrimitiveType.INT);
    :}
    | KW_INT LPAREN INTEGER_LITERAL:length RPAREN
    {:
        RESULT = ColumnType.createType(PrimitiveType.INT);
    :}
    | KW_BIGINT
    {:
        RESULT = ColumnType.createType(PrimitiveType.BIGINT);
    :}
    | KW_BIGINT LPAREN INTEGER_LITERAL:length RPAREN
    {:
        RESULT = ColumnType.createType(PrimitiveType.BIGINT);
    :}
    | KW_LARGEINT
    {:
        RESULT = ColumnType.createType(PrimitiveType.LARGEINT);
    :}
    | KW_LARGEINT LPAREN INTEGER_LITERAL:length RPAREN
    {:
        RESULT = ColumnType.createType(PrimitiveType.LARGEINT);
    :}
    | KW_FLOAT
    {:
        RESULT = ColumnType.createType(PrimitiveType.FLOAT);
    :}
    | KW_DOUBLE
    {:
        RESULT = ColumnType.createType(PrimitiveType.DOUBLE);
    :}
    | KW_DECIMAL
    {:
        RESULT = ColumnType.createDecimal(10, 0);
    :}
    | KW_DECIMAL LPAREN INTEGER_LITERAL:precision COMMA INTEGER_LITERAL:scale RPAREN
    {:
        RESULT = ColumnType.createDecimal(precision.intValue(), scale.intValue());
    :}
    | KW_DATE
    {:
        RESULT = ColumnType.createType(PrimitiveType.DATE);
    :}
    | KW_DATETIME
    {:
        RESULT = ColumnType.createType(PrimitiveType.DATETIME);
    :}
    | KW_CHAR
    {:
        RESULT = ColumnType.createChar(1);
    :}
    | KW_CHAR LPAREN INTEGER_LITERAL:length RPAREN
    {:
        RESULT = ColumnType.createChar(length.intValue());
    :}
    | KW_VARCHAR LPAREN INTEGER_LITERAL:length RPAREN
    {:
        RESULT = ColumnType.createVarchar(length.intValue());
    :}
    | KW_HLL
    {:
        RESULT = ColumnType.createHll();
    :}
    ;

opt_default_value ::=
    /* Empty */
    {:
        RESULT = null;
    :}
    | KW_DEFAULT STRING_LITERAL:value
    {:
        RESULT = value;
    :}
    | KW_DEFAULT KW_NULL
    {:
        RESULT = null;
    :}
    ;
    
opt_is_key ::=
	{:
		RESULT = false;
	:}
	| KW_KEY:key
	{:
		RESULT = true;
	:}
	;
	
column_definition ::=
    ident:columnName column_type:dataType opt_is_key:isKey opt_agg_type:aggType opt_is_allow_null:isAllowNull opt_default_value:defaultValue opt_comment:comment
    {:
        Column column = new Column(columnName, dataType, isKey, aggType, isAllowNull, defaultValue, comment);
        RESULT = column;
    :}
    ;

opt_is_allow_null ::=
    {:
        RESULT = true;
    :}
    | KW_NULL
    {:
        RESULT = true;
    :}
    | KW_NOT KW_NULL
    {:
        RESULT = false;
    :}
    ;

opt_comment ::=
    /* empty */
    {:
        RESULT = "";
    :}
    | KW_COMMENT STRING_LITERAL:comment
    {:
        RESULT = comment;
    :}
    ;

opt_if_exists ::=
    {:
        RESULT = false;
    :}
    | KW_IF KW_EXISTS
    {:
        RESULT = true;
    :}
    ;

opt_if_not_exists ::=
    {:
        RESULT = false;
    :}
    | KW_IF KW_NOT KW_EXISTS
    {:
        RESULT = true;
    :}
    ;
    
opt_external ::=
    /* empty */
    {:
        RESULT = false;
    :}
    | KW_EXTERNAL
    {:
        RESULT = true;
    :}
    ;

// Show statement
show_stmt ::=
    KW_SHOW show_param:stmt
    {:
        RESULT = stmt;
    :}
    ;

show_param ::=
	KW_WHITELIST
	{:
		RESULT = new ShowWhiteListStmt();
	:}
    /* show variables */
    | opt_var_type:type KW_VARIABLES opt_wild_where
    {:
        RESULT = new ShowVariablesStmt(type, parser.wild, parser.where);
    :}
    /* show open tables */
    | KW_OPEN KW_TABLES opt_db:db opt_wild_where
    {:
        RESULT = new ShowOpenTableStmt();
    :}
    /* show table status */
    | KW_TABLE KW_STATUS opt_db:db opt_wild_where
    {:
        RESULT = new ShowTableStatusStmt(db, parser.wild, parser.where);
    :}
    /* show table status */
    | opt_full KW_TABLES opt_db:db opt_wild_where
    {:
        RESULT = new ShowTableStmt(db, parser.isVerbose, parser.wild, parser.where);
    :}
    /* show processlist */
    | opt_full KW_PROCESSLIST
    {:
        RESULT = new ShowProcesslistStmt();
    :}
    /* show keys */
    | keys_or_index from_or_in table_ref:table opt_db:db where_clause:e
    {:
        RESULT = new ShowKeysStmt();
    :}
    /* routine */
    | procedure_or_function KW_STATUS opt_wild_where
    {:
        RESULT = new ShowProcedureStmt();
    :}
    /* status */
    | opt_var_type KW_STATUS opt_wild_where
    {:
        RESULT = new ShowStatusStmt();
    :}
    /* triggers */
    | opt_full KW_TRIGGERS opt_db:db opt_wild_where
    {:
        RESULT = new ShowTriggersStmt();
    :}
    /* events */
    | KW_EVENTS opt_db:db opt_wild_where
    {:
        RESULT = new ShowEventsStmt();
    :}
    /* plugins */
    | KW_PLUGINS
    {:
        RESULT = new ShowPluginsStmt();
    :}
    /* engines */
    | opt_storage KW_ENGINES
    {:
        RESULT = new ShowEnginesStmt();
    :}
    /* Authors */
    | KW_AUTHORS
    {:
        RESULT = new ShowAuthorStmt();
    :}
    /* Create table */
    | KW_CREATE KW_TABLE table_name:table
    {:
        RESULT = new ShowCreateTableStmt(table);
    :}
    | KW_CREATE KW_VIEW table_name:table
    {:
        RESULT = new ShowCreateTableStmt(table, true);
    :}
    /* Create database */
    | KW_CREATE KW_DATABASE ident:db
    {:
        RESULT = new ShowCreateDbStmt(db);
    :}
    /* Cluster */
    | KW_CLUSTERS
    {:
        RESULT = new ShowClusterStmt();
    :}
    | KW_MIGRATIONS
    {:
        RESULT = new ShowMigrationsStmt();
    :}
    /* Database */
    | KW_DATABASES opt_wild_where
    {:
        RESULT = new ShowDbStmt(parser.wild, parser.where);
    :}
    /* Columns */
    | opt_full KW_COLUMNS from_or_in table_name:table opt_db:db opt_wild_where
    {:
        RESULT = new ShowColumnStmt(table, db, parser.wild, parser.isVerbose, parser.where);
    :}
    /* collation */
    | KW_COLLATION opt_wild_where
    {:
        RESULT = new ShowCollationStmt(parser.wild);
    :}
    /* Show charset */
    | charset opt_wild_where
    {:
        RESULT = new ShowCharsetStmt(parser.wild);
    :}
    /* Show proc */
    | KW_PROC STRING_LITERAL:path
    {:
        RESULT = new ShowProcStmt(path);
    :}
    /* Show Warnings */
    | KW_COUNT LPAREN STAR RPAREN KW_WARNINGS
    {:
        SelectList list = new SelectList();
        list.addItem(new SelectListItem(new IntLiteral((long)0), null));
        RESULT = new SelectStmt(list, null, null, null, null, null, null);
    :}
    | KW_COUNT LPAREN STAR RPAREN KW_ERRORS
    {:
        SelectList list = new SelectList();
        list.addItem(new SelectListItem(new IntLiteral((long)0), null));
        RESULT = new SelectStmt(list, null, null, null, null, null, null);
    :}
    | KW_WARNINGS limit_clause
    {:
        RESULT = new ShowWarningStmt();
    :}
    | KW_ERRORS limit_clause
    {:
        RESULT = new ShowWarningStmt();
    :}
    // show load warnings
    | KW_LOAD KW_WARNINGS opt_db:db opt_wild_where limit_clause:limitClause
    {:
        RESULT = new ShowLoadWarningsStmt(db, parser.where, limitClause);
    :}
    /* Show load statement */
    | KW_LOAD opt_db:db opt_wild_where order_by_clause:orderByClause limit_clause:limitClause
    {:
        RESULT = new ShowLoadStmt(db, parser.where, orderByClause, limitClause);
    :}
    /* Show export statement */
    | KW_EXPORT opt_db:db opt_wild_where order_by_clause:orderByClause limit_clause:limitClause
    {:
        RESULT = new ShowExportStmt(db, parser.where, orderByClause, limitClause);
    :}
    /* Show delete statement */
    | KW_DELETE opt_db:db
    {:
        RESULT = new ShowDeleteStmt(db);
    :}
    /* Show alter table statement: used to show process of alter table statement */
    | KW_ALTER KW_TABLE opt_alter_type:type opt_db:db
    {:
        RESULT = new ShowAlterStmt(type, db);
    :}
    /* Show data statement: used to show data size of specified range */
    | KW_DATA
    {:
        RESULT = new ShowDataStmt(null, null);
    :}
    | KW_DATA KW_FROM table_name:dbTblName
    {:
        RESULT = new ShowDataStmt(dbTblName.getDb(), dbTblName.getTbl());
    :}
	| KW_PARTITIONS KW_FROM table_name:tblName opt_partition_name:partitionName
    {:
        RESULT = new ShowPartitionsStmt(tblName, partitionName);
    :}
    | KW_TABLET INTEGER_LITERAL:tabletId
    {:
        RESULT = new ShowTabletStmt(null, tabletId);
    :}
    | KW_TABLET KW_FROM table_name:dbTblName
    {:
        RESULT = new ShowTabletStmt(dbTblName, -1L);
    :}
    | KW_PROPERTY opt_user:user opt_wild_where
    {:
        RESULT = new ShowUserPropertyStmt(user, parser.wild);
    :}
    | KW_BACKUP opt_db:db opt_wild_where
    {:
        RESULT = new ShowBackupStmt(db, parser.where);
    :}
    | KW_RESTORE opt_db:db opt_wild_where
    {:
        RESULT = new ShowRestoreStmt(db, parser.where);
    :}
    | KW_BROKER 
    {:
        RESULT = new ShowBrokerStmt();
    :}
    | KW_BACKENDS
    {:   
        RESULT = new ShowBackendsStmt();
    :} 
    ;

keys_or_index ::=
    KW_KEY
    | KW_INDEX
    | KW_INDEXES
    ;

opt_db ::=
    /* empty */
    {:
        RESULT = null;
    :}
    | from_or_in ident:db
    {:
        RESULT = db;
    :}
    ;

opt_partition_name ::=
    /* empty */
    {:
        RESULT = null;
    :}
    | KW_PARTITION ident:partitionName
    {:
        RESULT = partitionName;
    :}
    ;

charset ::=
    KW_CHAR KW_SET
    | KW_CHARSET
    ;

charset_name_or_default ::=
    ident_or_text:id
    {:
        RESULT = id;
    :}
    | KW_DEFAULT
    {:
        RESULT = null;
    :}
    ;

old_or_new_charset_name_or_default ::=
    ident_or_text:id
    {:
        RESULT = id;
    :}
    | KW_DEFAULT
    {:
        RESULT = null;
    :}
    ;

opt_collate ::=
    /* Empty */
    {:
        RESULT = null;
    :}
    | KW_COLLATE collation_name_or_default:collate
    {:
        RESULT = collate;
    :}
    ;

collation_name_or_default ::=
    ident_or_text:id
    {:
        RESULT = id;
    :}
    | KW_DEFAULT
    {:
        RESULT = null;
    :}
    ;

opt_storage ::=
    /* Empty */
    | KW_STORAGE
    ;

procedure_or_function ::=
    KW_PROCEDURE
    | KW_FUNCTION
    ;

from_or_in ::=
    KW_FROM
    | KW_IN
    ;

opt_full ::=
    /* empty */
    {:
        parser.isVerbose = false;
    :}
    | KW_FULL
    {:
        parser.isVerbose = true;
    :}
    ;

opt_wild_where ::=
    /* empty */
    | KW_LIKE STRING_LITERAL:wild
    {:
        parser.wild = wild;
    :}
    | KW_WHERE expr:where
    {:
        parser.where = where;
    :}
    ;

opt_alter_type ::=
    KW_ROLLUP
    {:
        RESULT = ShowAlterStmt.AlterType.ROLLUP;
    :}
    | KW_COLUMN
    {:
        RESULT = ShowAlterStmt.AlterType.COLUMN;
    :}
    ;

// Describe statement
describe_stmt ::=
    describe_command table_name:table
    {:
        RESULT = new DescribeStmt(table, false);
    :}
    | describe_command table_name:table KW_ALL
    {:
        RESULT = new DescribeStmt(table, true);
    :}
    | describe_command query_stmt:query
    {:
        query.setIsExplain(true);
        RESULT = query;
    :}
    | describe_command insert_stmt:stmt
    {:
        stmt.getQueryStmt().setIsExplain(true);
        RESULT = stmt;
    :}
    ;

describe_command ::=
    KW_DESCRIBE
    | KW_DESC
    ;

// Cancel statement
cancel_stmt ::=
    KW_CANCEL cancel_param:stmt
    {:
        RESULT = stmt;
    :}
    ;

cancel_param ::=
    KW_LOAD opt_db:db opt_wild_where
    {:
        RESULT = new CancelLoadStmt(db, parser.where);
    :}
    | KW_ALTER KW_TABLE opt_alter_type:type KW_FROM table_name:table
    {:
        RESULT = new CancelAlterTableStmt(type, table);
    :}
    | KW_DECOMMISSION KW_BACKEND string_list:hostPorts
    {:
        RESULT = new CancelAlterSystemStmt(hostPorts);
    :}
    | KW_BACKUP opt_db:db
    {:
        RESULT = new CancelBackupStmt(db, false);
    :}
    | KW_RESTORE opt_db:db
    {:
        RESULT = new CancelBackupStmt(db, true);
    :}
    ;

// Delete stmt
delete_stmt ::=
    KW_DELETE KW_FROM table_name:table KW_PARTITION ident:partition where_clause:wherePredicate
    opt_properties:properties
    {:
        RESULT = new DeleteStmt(table, partition, wherePredicate, properties);
    :}
    ;

// Our parsing of UNION is slightly different from MySQL's:
// http://dev.mysql.com/doc/refman/5.5/en/union.html
//
// Imo, MySQL's parsing of union is not very clear.
// For example, MySQL cannot parse this query:
// select 3 order by 1 limit 1 union all select 1;
//
// On the other hand, MySQL does parse this query, but associates
// the order by and limit with the union, not the select:
// select 3 as g union all select 1 order by 1 limit 2;
//
// MySQL also allows some combinations of select blocks
// with and without parenthesis, but also disallows others.
//
// Our parsing:
// Select blocks may or may not be in parenthesis,
// even if the union has order by and limit.
// ORDER BY and LIMIT bind to the preceding select statement by default.
query_stmt ::=
    opt_with_clause:w union_operand_list:operands
    {:
        QueryStmt queryStmt = null;
        if (operands.size() == 1) {
          queryStmt = operands.get(0).getQueryStmt();
        } else {
          queryStmt = new UnionStmt(operands, null, LimitElement.NO_LIMIT);
        }
        queryStmt.setWithClause(w);
        RESULT = queryStmt;
    :}
    | opt_with_clause:w union_with_order_by_or_limit:union
    {: 
        union.setWithClause(w);
        RESULT = union; 
    :}
    ;

opt_with_clause ::=
    KW_WITH with_view_def_list:list
    {: RESULT = new WithClause(list); :}
    | /* empty */
    {: RESULT = null; :}
    ;

with_view_def ::=
    ident:alias KW_AS LPAREN query_stmt:query RPAREN
    {: RESULT = new View(alias, query, null); :}
    | STRING_LITERAL:alias KW_AS LPAREN query_stmt:query RPAREN
    {: RESULT = new View(alias, query, null); :}
    | ident:alias LPAREN ident_list:col_names RPAREN KW_AS LPAREN
      query_stmt:query RPAREN
    {: RESULT = new View(alias, query, col_names); :}
    | STRING_LITERAL:alias LPAREN ident_list:col_names RPAREN
      KW_AS LPAREN query_stmt:query RPAREN
    {: RESULT = new View(alias, query, col_names); :}
    ;

with_view_def_list ::=
    with_view_def:v
    {:
        ArrayList<View> list = new ArrayList<View>();
        list.add(v);
        RESULT = list;
    :}
    | with_view_def_list:list COMMA with_view_def:v
    {:
        list.add(v);
        RESULT = list;
    :}
    ;

// We must have a non-empty order by or limit for them to bind to the union.
// We cannot reuse the existing order_by_clause or
// limit_clause because they would introduce conflicts with EOF,
// which, unfortunately, cannot be accessed in the parser as a nonterminal
// making this issue unresolvable.
// We rely on the left precedence of KW_ORDER, KW_BY, and KW_LIMIT,
// to resolve the ambiguity with select_stmt in favor of select_stmt
// (i.e., ORDER BY and LIMIT bind to the select_stmt by default, and not the union).
// There must be at least two union operands for ORDER BY or LIMIT to bind to a union,
// and we manually throw a parse error if we reach this production
// with only a single operand.
union_with_order_by_or_limit ::=
    union_operand_list:operands
    KW_LIMIT INTEGER_LITERAL:limit
  {:
    if (operands.size() == 1) {
      parser.parseError("limit", SqlParserSymbols.KW_LIMIT);
    }
    RESULT = new UnionStmt(operands, null, new LimitElement(limit.longValue()));
  :}
  |
    union_operand_list:operands
    KW_LIMIT INTEGER_LITERAL:offset COMMA INTEGER_LITERAL:limit
  {:
    if (operands.size() == 1) {
      parser.parseError("limit", SqlParserSymbols.KW_LIMIT);
    }
    RESULT = new UnionStmt(operands, null, new LimitElement(offset.longValue(), limit.longValue()));
  :}
  |
    union_operand_list:operands
    KW_LIMIT INTEGER_LITERAL:limit KW_OFFSET INTEGER_LITERAL:offset
  {:
    if (operands.size() == 1) {
      parser.parseError("limit", SqlParserSymbols.KW_LIMIT);
    }
    RESULT = new UnionStmt(operands, null, new LimitElement(offset.longValue(), limit.longValue()));
  :}
  |
    union_operand_list:operands
    KW_ORDER KW_BY order_by_elements:orderByClause
  {:
    if (operands.size() == 1) {
      parser.parseError("order", SqlParserSymbols.KW_ORDER);
    }
    RESULT = new UnionStmt(operands, orderByClause, LimitElement.NO_LIMIT);
  :}
  |
    union_operand_list:operands
    KW_ORDER KW_BY order_by_elements:orderByClause
    KW_LIMIT INTEGER_LITERAL:limit
  {:
    if (operands.size() == 1) {
      parser.parseError("order", SqlParserSymbols.KW_ORDER);
    }
    RESULT = new UnionStmt(operands, orderByClause, new LimitElement(limit.longValue()));
  :}
  |
    union_operand_list:operands
    KW_ORDER KW_BY order_by_elements:orderByClause
    KW_LIMIT INTEGER_LITERAL:offset COMMA INTEGER_LITERAL:limit
  {:
    if (operands.size() == 1) {
      parser.parseError("order", SqlParserSymbols.KW_ORDER);
    }
    RESULT = new UnionStmt(operands, orderByClause, new LimitElement(offset.longValue(), limit.longValue()));
  :}
  |
    union_operand_list:operands
    KW_ORDER KW_BY order_by_elements:orderByClause
    KW_LIMIT INTEGER_LITERAL:limit KW_OFFSET INTEGER_LITERAL:offset
  {:
    if (operands.size() == 1) {
      parser.parseError("order", SqlParserSymbols.KW_ORDER);
    }
    RESULT = new UnionStmt(operands, orderByClause, new LimitElement(offset.longValue(), limit.longValue()));
  :}
  ;


union_operand ::=
  select_stmt:select
  {:
    RESULT = select;
  :}
  | LPAREN query_stmt:query RPAREN
  {:
    RESULT = query;
  :}
  ;

union_operand_list ::=
  union_operand:operand
  {:
    List<UnionOperand> operands = new ArrayList<UnionOperand>();
    operands.add(new UnionOperand(operand, null));
    RESULT = operands;
  :}
  | union_operand_list:operands union_op:op union_operand:operand
  {:
    operands.add(new UnionOperand(operand, op));
    RESULT = operands;
  :}
  ;

union_op ::=
  KW_UNION
  {: RESULT = Qualifier.DISTINCT; :}
  | KW_UNION KW_DISTINCT
  {: RESULT = Qualifier.DISTINCT; :}
  | KW_UNION KW_ALL
  {: RESULT = Qualifier.ALL; :}
  ;

// Change cluster
enter_stmt ::=
    KW_ENTER ident:cluster
    {:
        RESULT = new EnterStmt(cluster);
    :}
    ;
// Change database
use_stmt ::=
    KW_USE ident:db
    {:
        RESULT = new UseStmt(db);
    :}
    ;

// Insert statement
insert_stmt ::=
    KW_INSERT KW_INTO insert_target:target opt_col_list:cols opt_plan_hints:hints insert_source:source
    {:
        RESULT = new InsertStmt(target, cols, source, hints);
    :}
    // TODO(zc) add default value for SQL-2003
    // | KW_INSERT KW_INTO insert_target:target KW_DEFAULT KW_VALUES
    ;

insert_target ::=
    table_name:tbl opt_using_partition:partitions
    {:
        RESULT = new InsertTarget(tbl, partitions);
    :}
    ;

insert_source ::=
    query_stmt:query
    {:
        RESULT = new InsertSource(query);
    :}
    ;

// backup stmt
backup_stmt ::=
    KW_BACKUP KW_LABEL job_label:label
	opt_partition_name_list:backupObjNames
    KW_INTO STRING_LITERAL:rootPath
    opt_properties:properties
    {:
        RESULT = new BackupStmt(label, backupObjNames, rootPath, properties);
    :}
    ;

// Restore statement
restore_stmt ::=
    KW_RESTORE KW_LABEL job_label:label
	opt_partition_name_list:restoreObjNames
    KW_FROM STRING_LITERAL:rootPath
    opt_properties:properties
    {:
        RESULT = new RestoreStmt(label, restoreObjNames, rootPath, properties);
    :}
    ;

opt_partition_name_list ::=
	/* Empty */
	{:
		RESULT = Lists.newArrayList();
	:}
	| LPAREN partition_name_list:list RPAREN
	{:
		RESULT = list;
	:}
	;

partition_name_list ::=
    partition_name:partitionName
    {:
        RESULT = Lists.newArrayList(partitionName);
    :}
    | partition_name_list:list COMMA partition_name:partitionName
    {:
        list.add(partitionName);
        RESULT = list;
    :}
    ;

partition_name ::=
    ident:tbl
    {:
        RESULT = new PartitionName(tbl, null, null, null);
    :}
    | ident:tbl KW_AS ident:newTbl
    {:
        RESULT = new PartitionName(tbl, newTbl, null, null);
    :}
    | ident:tbl DOT ident:partition
    {:
        RESULT = new PartitionName(tbl, null, partition, null);
    :}
    | ident:tbl DOT ident:partition KW_AS ident:newTbl DOT ident:newPartition
    {:
        RESULT = new PartitionName(tbl, newTbl, partition, newPartition);
    :}
    ;

// Kill statement
kill_stmt ::=
    KW_KILL INTEGER_LITERAL:value
    {:
        RESULT = new KillStmt(true, value.longValue());
    :}
    | KW_KILL KW_CONNECTION INTEGER_LITERAL:value
    {:
        RESULT = new KillStmt(true, value.longValue());
    :}
    | KW_KILL KW_QUERY INTEGER_LITERAL:value
    {:
        RESULT = new KillStmt(false, value.longValue());
    :}
    ;

// TODO(zhaochun): stolen from MySQL. Why not use value list, maybe avoid shift/reduce conflict
// Set statement
set_stmt ::=
    KW_SET start_option_value_list:list
    {:
        RESULT = new SetStmt(list);
    :}
    | KW_SET KW_PROPERTY opt_user:user user_property_list:property_list
    {:
        RESULT = new SetUserPropertyStmt(user, property_list);
    :}
    ;

user_property_list ::=
    user_property:property
    {:
        RESULT = Lists.newArrayList(property);
    :}
    | user_property_list:list COMMA user_property:property
    {:
        list.add(property);
        RESULT = list;
    :}
    ;

user_property ::=
    STRING_LITERAL:key equal STRING_LITERAL:value
    {:
        RESULT = new SetUserPropertyVar(key, value);
    :}
    | STRING_LITERAL:key equal KW_NULL
    {:
        RESULT = new SetUserPropertyVar(key, null);
    :}
    ;

// Start of set value list
start_option_value_list ::=
    /* Variable starts with keyword and have no option */
    option_value_no_option_type:value option_value_list_continued:list
    {:
        if (list == null) {
            list = Lists.newArrayList(value);
        } else {
            list.add(value);
        }
        RESULT = list;
    :}
    /* Do not support transaction, return null */
    | KW_TRANSACTION transaction_characteristics
    {:
        RESULT = Lists.newArrayList((SetVar) new SetTransaction());
    :}
    | option_type:type start_option_value_list_following_option_type:list
    {:
        if (list == null || list.isEmpty()) {
        } else {
            list.get(0).setType(type);
        }
        RESULT = list;
    :}
    ;

// Following the start of value list with option
start_option_value_list_following_option_type ::=
    option_value_follow_option_type:var option_value_list_continued:list
    {:
        list.add(var);
        RESULT = list;
    :}
    | KW_TRANSACTION transaction_characteristics
    {:
        RESULT = Lists.newArrayList((SetVar) new SetTransaction());
    :}
    ;

// option values after first value;
option_value_list_continued ::=
    /* empty */
    {:
        RESULT = Lists.newArrayList();
    :}
    | COMMA option_value_list:list
    {:
        RESULT = list;
    :}
    ;

option_value_list ::=
    option_value:var
    {:
        RESULT = Lists.newArrayList(var);
    :}
    | option_value_list:list COMMA option_value:item
    {:
        list.add(item);
        RESULT = list;
    :}
    ;

option_value ::=
    option_type:type option_value_follow_option_type:var
    {:
        var.setType(type);
        RESULT = var;
    :}
    | option_value_no_option_type:var
    {:
        RESULT = var;
    :}
    ;

option_value_follow_option_type ::=
    variable_name:variable equal set_expr_or_default:expr
    {:
        RESULT = new SetVar(variable, expr);
    :}
    ;

option_value_no_option_type ::=
    /* Normal set value */
    variable_name:variable equal set_expr_or_default:expr
    {:
        RESULT = new SetVar(variable, expr);
    :}
    | AT ident_or_text:var equal literal:expr
    {:
        RESULT = new SetVar(var, expr);
    :}
    /* Ident */
    | AT AT variable_name:variable equal set_expr_or_default:expr
    {:
        RESULT = new SetVar(variable, expr);
    :}
    | AT AT var_ident_type:type variable_name:variable equal set_expr_or_default:expr
    {:
        RESULT = new SetVar(type, variable, expr);
    :}
    /* charset */
    | charset old_or_new_charset_name_or_default:charset
    {:
        RESULT = new SetNamesVar(charset);
    :}
    | KW_NAMES equal expr
    {:
        parser.parseError("names", SqlParserSymbols.KW_NAMES);
    :}
    | KW_NAMES charset_name_or_default:charset opt_collate:collate
    {:
        RESULT = new SetNamesVar(charset, collate);
    :}
    /* Password */
    | KW_PASSWORD equal text_or_password:passwd
    {:
        RESULT = new SetPassVar(null, passwd);
    :}
    | KW_PASSWORD KW_FOR STRING_LITERAL:user equal text_or_password:passwd
    {:
        RESULT = new SetPassVar(user, passwd);
    :}
    ;

variable_name ::=
    ident:name
    {:
        RESULT = name;
    :}
    ;

text_or_password ::=
    STRING_LITERAL:text
    {:
        // This is hashed text
        RESULT = text;
    :}
    | KW_PASSWORD LPAREN STRING_LITERAL:passwd RPAREN
    {:
        // This is plain text
        RESULT = new String(MysqlPassword.makeScrambledPassword(passwd));
    :}
    ;

option_type ::=
    KW_GLOBAL
    {:
        RESULT = SetType.GLOBAL;
    :}
    | KW_LOCAL
    {:
        RESULT = SetType.SESSION;
    :}
    | KW_SESSION
    {:
        RESULT = SetType.SESSION;
    :}
    ;

opt_var_type ::=
    /* empty */
    {: RESULT = SetType.DEFAULT; :}
    | KW_GLOBAL
    {: RESULT = SetType.GLOBAL; :}
    | KW_LOCAL
    {: RESULT = SetType.SESSION; :}
    | KW_SESSION
    {: RESULT = SetType.SESSION; :}
    ;

var_ident_type ::=
    KW_GLOBAL DOT
    {:
        RESULT = SetType.GLOBAL;
    :}
    | KW_LOCAL DOT
    {:
        RESULT = SetType.SESSION;
    :}
    | KW_SESSION DOT
    {:
        RESULT = SetType.SESSION;
    :}
    ;

equal ::=
    EQUAL
    | SET_VAR
    ;

transaction_characteristics ::=
    transaction_access_mode
    | isolation_level
    | transaction_access_mode COMMA isolation_level
    | isolation_level COMMA transaction_access_mode
    ;

transaction_access_mode ::=
    KW_READ KW_ONLY
    | KW_READ KW_WRITE
    ;

isolation_level ::=
    KW_ISOLATION KW_LEVEL isolation_types
    ;

isolation_types ::=
    KW_READ KW_UNCOMMITTED
    | KW_READ KW_COMMITTED
    | KW_REPEATABLE KW_READ
    | KW_SERIALIZABLE
    ;

set_expr_or_default ::=
    literal:value
    {:
        RESULT = value;
    :}
    | KW_DEFAULT
    {:
        RESULT = null;
    :}
    | KW_ON
    {:
        RESULT = new StringLiteral("ON");
    :}
    | KW_ALL
    {:
        RESULT = new StringLiteral("ALL");
    :}
    | ident:name
    {:
        RESULT = new StringLiteral(name);
    :}
    ;

select_stmt ::=
  select_clause:selectList
    limit_clause:limitClause
  {: RESULT = new SelectStmt(selectList, null, null, null, null, null, limitClause); :}
  | select_clause:selectList
    from_clause:fromClause
    where_clause:wherePredicate
    group_by_clause:groupingExprs
    having_clause:havingPredicate
    order_by_clause:orderByClause
    limit_clause:limitClause
  {:
    RESULT = new SelectStmt(selectList, fromClause, wherePredicate,
                            groupingExprs, havingPredicate, orderByClause,
                            limitClause);
  :}
  ;

select_clause ::=
    KW_SELECT select_list:l
    {:
        RESULT = l;
    :}
    | KW_SELECT KW_ALL select_list:l
    {:
        RESULT = l;
    :}
    | KW_SELECT KW_DISTINCT select_list:l
    {:
        l.setIsDistinct(true);
        RESULT = l;
    :}
    ;

select_list ::=
    select_sublist:list
    {:
        RESULT = list;
    :}
    | STAR
    {:
        SelectList list = new SelectList();
        list.addItem(SelectListItem.createStarItem(null));
        RESULT = list;
    :}
    ;

select_sublist ::=
    select_sublist:list COMMA select_list_item:item
    {:
        list.addItem(item);
        RESULT = list;
    :}
    | select_sublist:list COMMA STAR
    {:
        list.addItem(SelectListItem.createStarItem(null));
        RESULT = list;
    :}
    // why not use "STAR COMMA select_sublist",for we analyze from left to right
    | STAR COMMA select_list_item:item
    {:
        SelectList list = new SelectList();
        list.addItem(SelectListItem.createStarItem(null));
        list.addItem(item);
        RESULT = list;
    :}
    | select_list_item:item
    {:
        SelectList list = new SelectList();
        list.addItem(item);
        RESULT = list;
    :}
    ;

select_list_item ::=
    expr:expr select_alias:alias
    {:
        RESULT = new SelectListItem(expr, alias);
    :}
    | star_expr:expr
    {:
        RESULT = expr;
    :}
    ;

select_alias ::=
    /* empty */
    {:
        RESULT = null;
    :}
    | KW_AS ident:ident
    {:
        RESULT = ident;
    :}
    | ident:ident
    {:
        RESULT = ident;
    :}
    | KW_AS STRING_LITERAL:l
    {:
        RESULT = l;
    :}
    | STRING_LITERAL:l
    {:
        RESULT = l;
    :}
    ;

star_expr ::=
    // table_name DOT STAR doesn't work because of a reduce-reduce conflict
    // on IDENT [DOT]
    ident:tbl DOT STAR
    {:
        RESULT = SelectListItem.createStarItem(new TableName(null, tbl));
    :}
    | ident:db DOT ident:tbl DOT STAR
    {:
        RESULT = SelectListItem.createStarItem(new TableName(db, tbl));
    :}
    ;

table_name ::=
    ident:tbl
    {: RESULT = new TableName(null, tbl); :}
    | ident:db DOT ident:tbl
    {: RESULT = new TableName(db, tbl); :}
    ;

function_name ::=
    ident:fn
    {: RESULT = new FunctionName(null, fn); :}
    | ident:db DOT ident:fn
    {: RESULT = new FunctionName(db, fn); :}
    ;

from_clause ::=
    KW_FROM table_ref_list:l
    {: RESULT = new FromClause(l); :}
    ;

table_ref_list ::=
  table_ref:t opt_sort_hints:h
  {:
    ArrayList<TableRef> list = new ArrayList<TableRef>();
    t.setSortHints(h);
    list.add(t);
    RESULT = list;
  :}
  | table_ref_list:list COMMA table_ref:table opt_sort_hints:h
  {:
    table.setSortHints(h);
    list.add(table);
    RESULT = list;
  :}
  | table_ref_list:list join_operator:op opt_plan_hints:hints table_ref:table opt_sort_hints:h
  {:
    table.setJoinOp((JoinOperator) op);
    table.setJoinHints(hints);
    table.setSortHints(h);
    list.add(table);
    RESULT = list;
  :}
  | table_ref_list:list join_operator:op opt_plan_hints:hints table_ref:table opt_sort_hints:h
    KW_ON expr:e
  {:
    table.setJoinOp((JoinOperator) op);
    table.setJoinHints(hints);
    table.setOnClause(e);
    table.setSortHints(h);
    list.add(table);
    RESULT = list;
  :}
  | table_ref_list:list join_operator:op opt_plan_hints:hints table_ref:table opt_sort_hints:h
    KW_USING LPAREN ident_list:colNames RPAREN
  {:
    table.setJoinOp((JoinOperator) op);
    table.setJoinHints(hints);
    table.setUsingClause(colNames);
    table.setSortHints(h);
    list.add(table);
    RESULT = list;
  :}
  ;

table_ref ::=
  base_table_ref:b
  {: RESULT = b; :}
  | inline_view_ref:s
  {: RESULT = s; :}
  ;

inline_view_ref ::=
    LPAREN query_stmt:query RPAREN opt_table_alias:alias
    {:
        RESULT = new InlineViewRef(alias, query);
    :}
    ;

base_table_ref ::=
    table_name:name opt_using_partition:parts opt_table_alias:alias
    {:
        RESULT = new TableRef(name, alias, parts);
    :}
    ;

opt_table_alias ::=
    /* empty */
    {:
        RESULT = null;
    :}
    | ident:alias
    {:
        RESULT = alias;
    :}
    | KW_AS ident:alias
    {:
        RESULT = alias;
    :}
    | EQUAL ident:alias
    {:
        RESULT = alias;
    :}
    ;

opt_using_partition ::=
    /* empty */
    {:
        RESULT = null;
    :}
    | KW_PARTITION LPAREN ident_list:partitions RPAREN
    {:
        RESULT = partitions;
    :}
    ;

join_operator ::=
  opt_inner KW_JOIN
  {: RESULT = JoinOperator.INNER_JOIN; :}
  | KW_LEFT opt_outer KW_JOIN
  {: RESULT = JoinOperator.LEFT_OUTER_JOIN; :}
  | KW_MERGE KW_JOIN
  {: RESULT = JoinOperator.MERGE_JOIN; :}
  | KW_RIGHT opt_outer KW_JOIN
  {: RESULT = JoinOperator.RIGHT_OUTER_JOIN; :}
  | KW_FULL opt_outer KW_JOIN
  {: RESULT = JoinOperator.FULL_OUTER_JOIN; :}
  | KW_LEFT KW_SEMI KW_JOIN
  {: RESULT = JoinOperator.LEFT_SEMI_JOIN; :}
  | KW_RIGHT KW_SEMI KW_JOIN
  {: RESULT = JoinOperator.RIGHT_SEMI_JOIN; :}
  | KW_LEFT KW_ANTI KW_JOIN
  {: RESULT = JoinOperator.LEFT_ANTI_JOIN; :}
  | KW_RIGHT KW_ANTI KW_JOIN
  {: RESULT = JoinOperator.RIGHT_ANTI_JOIN; :}
  | KW_CROSS KW_JOIN
  {: RESULT = JoinOperator.CROSS_JOIN; :}
  ;

opt_inner ::=
  KW_INNER
  |
  ;

opt_outer ::=
  KW_OUTER
  |
  ;

opt_plan_hints ::=
    COMMENTED_PLAN_HINTS:l
    {:
        ArrayList<String> hints = Lists.newArrayList();
        String[] tokens = l.split(",");
        for (String token: tokens) {
            String trimmedToken = token.trim();
            if (trimmedToken.length() > 0) {
                hints.add(trimmedToken);
            }
        }
        RESULT = hints;
    :}
    | LBRACKET ident_list:l RBRACKET
    {:
        RESULT = l;
    :}
    | /* empty */
    {:
        RESULT = null;
    :}
    ;

opt_sort_hints ::=
  LBRACKET ident_list:l RBRACKET
  {: RESULT = l; :}
  |
  {: RESULT = null; :}
  ;

ident_list ::=
    ident:ident
    {:
      ArrayList<String> list = new ArrayList<String>();
      list.add(ident);
      RESULT = list;
    :}
    | ident_list:list COMMA ident:ident
    {:
      list.add(ident);
      RESULT = list;
    :}
    ;

expr_list ::=
  expr:e
  {:
    ArrayList<Expr> list = new ArrayList<Expr>();
    list.add(e);
    RESULT = list;
  :}
  | expr_list:list COMMA expr:e
  {:
    list.add(e);
    RESULT = list;
  :}
  ;

where_clause ::=
  KW_WHERE expr:e
  {: RESULT = e; :}
  | /* empty */
  {: RESULT = null; :}
  ;

group_by_clause ::=
  KW_GROUP KW_BY expr_list:l
  {: RESULT = l; :}
  | /* empty */
  {: RESULT = null; :}
  ;

having_clause ::=
  KW_HAVING expr:e
  {: RESULT = e; :}
  | /* empty */
  {: RESULT = null; :}
  ;

order_by_clause ::=
  KW_ORDER KW_BY order_by_elements:l
  {: RESULT = l; :}
  | /* empty */
  {: RESULT = null; :}
  ;

order_by_elements ::=
  order_by_element:e
  {:
    ArrayList<OrderByElement> list = new ArrayList<OrderByElement>();
    list.add(e);
    RESULT = list;
  :}
  | order_by_elements:list COMMA order_by_element:e
  {:
    list.add(e);
    RESULT = list;
  :}
  ;

order_by_element ::=
  expr:e
  {: RESULT = new OrderByElement(e, true); :}
  | expr:e KW_ASC
  {: RESULT = new OrderByElement(e, true); :}
  | expr:e KW_DESC
  {: RESULT = new OrderByElement(e, false); :}
  ;

limit_clause ::=
  KW_LIMIT INTEGER_LITERAL:limit
  {: RESULT = new LimitElement(limit.longValue()); :}
  | /* empty */
  {: RESULT = LimitElement.NO_LIMIT; :}
  | KW_LIMIT INTEGER_LITERAL:offset COMMA INTEGER_LITERAL:limit
  {: RESULT = new LimitElement(offset.longValue(), limit.longValue()); :}
  | KW_LIMIT INTEGER_LITERAL:limit KW_OFFSET INTEGER_LITERAL:offset
  {: RESULT = new LimitElement(offset.longValue(), limit.longValue()); :}
  ;

cast_expr ::=
  KW_CAST LPAREN expr:e KW_AS KW_STRING RPAREN
  {: RESULT = new CastExpr(Type.VARCHAR, e, false); :}
  | KW_CAST LPAREN expr:e KW_AS primitive_type:targetType RPAREN
  {: RESULT = new CastExpr(Type.fromPrimitiveType((PrimitiveType) targetType), e, false); :}
  | KW_CAST LPAREN expr:e KW_AS primitive_type:targetType LPAREN non_pred_expr:e1 RPAREN RPAREN
  {: RESULT = new CastExpr(Type.fromPrimitiveType((PrimitiveType) targetType), e, false); :}
  ;

case_expr ::=
  KW_CASE expr:caseExpr
    case_when_clause_list:whenClauseList
    case_else_clause:elseExpr
    KW_END
  {: RESULT = new CaseExpr(caseExpr, whenClauseList, elseExpr); :}
  | KW_CASE
    case_when_clause_list:whenClauseList
    case_else_clause:elseExpr
    KW_END
  {: RESULT = new CaseExpr(null, whenClauseList, elseExpr); :}
  ;

case_when_clause_list ::=
  KW_WHEN expr:whenExpr KW_THEN expr:thenExpr
  {:
    ArrayList<CaseWhenClause> list = new ArrayList<CaseWhenClause>();
    list.add(new CaseWhenClause(whenExpr, thenExpr));
    RESULT = list;
  :}
  | case_when_clause_list:list KW_WHEN expr:whenExpr
    KW_THEN expr:thenExpr
  {:
    list.add(new CaseWhenClause(whenExpr, thenExpr));
    RESULT = list;
  :}
  ;

case_else_clause ::=
  KW_ELSE expr:e
  {: RESULT = e; :}
  | /* emtpy */
  {: RESULT = null; :}
  ;

sign_chain_expr ::=
  SUBTRACT expr:e
  {:
    // integrate signs into literals
    if (e.isLiteral() && e.getType().isNumericType()) {
      ((LiteralExpr)e).swapSign();
      RESULT = e;
    } else {
      RESULT = new ArithmeticExpr(ArithmeticExpr.Operator.MULTIPLY, new IntLiteral((long)-1), e);
    }
  :}
  | ADD expr:e
  {: RESULT = e; :}
  ;

expr ::=
  non_pred_expr:e
  {: RESULT = e; :}
  | predicate:p
  {: RESULT = p; :}
  ;

function_call_expr ::=
  function_name:fn_name LPAREN RPAREN
  {: RESULT = new FunctionCallExpr(fn_name, new ArrayList<Expr>()); :}
  | function_name:fn_name LPAREN function_params:params RPAREN
  {: RESULT = new FunctionCallExpr(fn_name, params); :}
  ;

exists_predicate ::=
  KW_EXISTS subquery:s
  {: RESULT = new ExistsPredicate(s, false); :}
  ;

non_pred_expr ::=
  sign_chain_expr:e
  {: RESULT = e; :}
  | AT AT ident:l
  {:
    RESULT = new SysVariableDesc(l);
  :}
  | AT AT var_ident_type:type ident:l
  {:
    RESULT = new SysVariableDesc(l, type);
  :}
  | literal:l
  {: RESULT = l; :}
  | function_call_expr:e
  {: RESULT = e; :}
  | KW_DATE STRING_LITERAL:l
  {: RESULT = new StringLiteral(l); :}
  | KW_TIMESTAMP STRING_LITERAL:l
  {: RESULT = new StringLiteral(l); :}
  | KW_EXTRACT LPAREN function_name:fn_name KW_FROM func_arg_list:exprs RPAREN
  {: RESULT = new FunctionCallExpr(fn_name, exprs); :}
  //| function_name:fn_name LPAREN RPAREN
  //{: RESULT = new FunctionCallExpr(fn_name, new ArrayList<Expr>()); :}
  //| function_name:fn_name LPAREN function_params:params RPAREN
  //{: RESULT = new FunctionCallExpr(fn_name, params); :}
  | analytic_expr:e
  {: RESULT = e; :}
  /* Since "IF" is a keyword, need to special case this function */
  | KW_IF LPAREN expr_list:exprs RPAREN
  {: RESULT = new FunctionCallExpr("if", exprs); :}
  | cast_expr:c
  {: RESULT = c; :}
  | case_expr:c
  {: RESULT = c; :}
  | column_ref:c
  {: RESULT = c; :}
  | timestamp_arithmetic_expr:e
  {: RESULT = e; :}
  | arithmetic_expr:e
  {: RESULT = e; :}
  | LPAREN non_pred_expr:e RPAREN
  {: RESULT = e; :}
  /* TODO(zc): add other trim function */
  | KW_TRIM:id LPAREN function_params:params RPAREN
  {: RESULT = new FunctionCallExpr(new FunctionName(null, id), params); :}
  | KW_DATABASE LPAREN RPAREN
  {: RESULT = new InformationFunction("DATABASE"); :}
  | KW_CURRENT_USER LPAREN RPAREN
  {: RESULT = new InformationFunction("CURRENT_USER"); :}
  | KW_CONNECTION_ID LPAREN RPAREN
  {: RESULT = new InformationFunction("CONNECTION_ID"); :}
  | KW_PASSWORD LPAREN STRING_LITERAL:text RPAREN
  {:
    RESULT = new StringLiteral(new String(MysqlPassword.makeScrambledPassword(text)));
  :}
  | subquery:s
  {: RESULT = s; :}
  |  KW_NULL KW_IS KW_NULL
  {: RESULT = new BoolLiteral(true); :}
  | KW_NULL KW_IS KW_NOT KW_NULL
  {: RESULT = new BoolLiteral(false); :}
  ;

func_arg_list ::=
  expr:item
  {:
    ArrayList<Expr> list = new ArrayList<Expr>();
    list.add(item);
    RESULT = list;
  :}
  | func_arg_list:list COMMA expr:item
  {:
    list.add(item);
    RESULT = list;
  :}
  ;

analytic_expr ::=
  function_call_expr:e KW_OVER LPAREN opt_partition_by_clause:p order_by_clause:o opt_window_clause:w RPAREN
  {:
    // Handle cases where function_call_expr resulted in a plain Expr
    if (!(e instanceof FunctionCallExpr)) {
      parser.parseError("over", SqlParserSymbols.KW_OVER);
    }
    FunctionCallExpr f = (FunctionCallExpr)e;
    f.setIsAnalyticFnCall(true);
    RESULT = new AnalyticExpr(f, p, o, w);
  :}
  %prec KW_OVER
  ;

opt_partition_by_clause ::=
  KW_PARTITION KW_BY expr_list:l
  {: RESULT = l; :}
  | /* empty */
  {: RESULT = null; :}
  ;

opt_window_clause ::=
  window_type:t window_boundary:b
  {: RESULT = new AnalyticWindow(t, b); :}
  | window_type:t KW_BETWEEN window_boundary:l KW_AND window_boundary:r
  {: RESULT = new AnalyticWindow(t, l, r); :}
  | /* empty */
  {: RESULT = null; :}
  ;

window_type ::=
  KW_ROWS
  {: RESULT = AnalyticWindow.Type.ROWS; :}
  | KW_RANGE
  {: RESULT = AnalyticWindow.Type.RANGE; :}
  ;

window_boundary ::=
  KW_UNBOUNDED KW_PRECEDING
  {:
    RESULT = new AnalyticWindow.Boundary(
        AnalyticWindow.BoundaryType.UNBOUNDED_PRECEDING, null);
  :}
  | KW_UNBOUNDED KW_FOLLOWING
  {:
    RESULT = new AnalyticWindow.Boundary(
        AnalyticWindow.BoundaryType.UNBOUNDED_FOLLOWING, null);
  :}
  | KW_CURRENT KW_ROW
  {:
    RESULT = new AnalyticWindow.Boundary(AnalyticWindow.BoundaryType.CURRENT_ROW, null);
  :}
  | expr:e KW_PRECEDING
  {: RESULT = new AnalyticWindow.Boundary(AnalyticWindow.BoundaryType.PRECEDING, e); :}
  | expr:e KW_FOLLOWING
  {: RESULT = new AnalyticWindow.Boundary(AnalyticWindow.BoundaryType.FOLLOWING, e); :}
  ;

arithmetic_expr ::=
  expr:e1 STAR expr:e2
  {: RESULT = new ArithmeticExpr(ArithmeticExpr.Operator.MULTIPLY, e1, e2); :}
  | expr:e1 DIVIDE expr:e2
  {: RESULT = new ArithmeticExpr(ArithmeticExpr.Operator.DIVIDE, e1, e2); :}
  | expr:e1 MOD expr:e2
  {: RESULT = new ArithmeticExpr(ArithmeticExpr.Operator.MOD, e1, e2); :}
  | expr:e1 KW_DIV expr:e2
  {: RESULT = new ArithmeticExpr(ArithmeticExpr.Operator.INT_DIVIDE, e1, e2); :}
  | expr:e1 ADD expr:e2
  {: RESULT = new ArithmeticExpr(ArithmeticExpr.Operator.ADD, e1, e2); :}
  | expr:e1 SUBTRACT expr:e2
  {: RESULT = new ArithmeticExpr(ArithmeticExpr.Operator.SUBTRACT, e1, e2); :}
  | expr:e1 BITAND expr:e2
  {: RESULT = new ArithmeticExpr(ArithmeticExpr.Operator.BITAND, e1, e2); :}
  | expr:e1 BITOR expr:e2
  {: RESULT = new ArithmeticExpr(ArithmeticExpr.Operator.BITOR, e1, e2); :}
  | expr:e1 BITXOR expr:e2
  {: RESULT = new ArithmeticExpr(ArithmeticExpr.Operator.BITXOR, e1, e2); :}
  | BITNOT expr:e
  {: RESULT = new ArithmeticExpr(ArithmeticExpr.Operator.BITNOT, e, null); :}
  ;

// We use IDENT for the temporal unit to avoid making DAY, YEAR, etc. keywords.
// This way we do not need to change existing uses of IDENT.
// We chose not to make DATE_ADD and DATE_SUB keywords for the same reason.
timestamp_arithmetic_expr ::=
  KW_INTERVAL expr:v ident:u ADD expr:t
  {: RESULT = new TimestampArithmeticExpr(ArithmeticExpr.Operator.ADD, t, v, u, true); :}
  | expr:t ADD KW_INTERVAL expr:v ident:u
  {:
    RESULT = new TimestampArithmeticExpr(ArithmeticExpr.Operator.ADD, t, v, u, false);
  :}
  // Set precedence to KW_INTERVAL (which is higher than ADD) for chaining.
  %prec KW_INTERVAL
  | expr:t SUBTRACT KW_INTERVAL expr:v ident:u
  {:
    RESULT =
        new TimestampArithmeticExpr(ArithmeticExpr.Operator.SUBTRACT, t, v, u, false);
  :}
  // Set precedence to KW_INTERVAL (which is higher than ADD) for chaining.
  %prec KW_INTERVAL
  // Timestamp arithmetic expr that looks like a function call.
  // We use func_arg_list instead of expr to avoid a shift/reduce conflict with
  // func_arg_list on COMMA, and report an error if the list contains more than one expr.
  // Although we don't want to accept function names as the expr, we can't parse it
  // it as just an IDENT due to the precedence conflict with function_name.
  | function_name:functionName LPAREN expr_list:l COMMA
    KW_INTERVAL expr:v ident:u RPAREN
  {:
    if (l.size() > 1) {
      // Report parsing failure on keyword interval.
      parser.parseError("interval", SqlParserSymbols.KW_INTERVAL);
    }
    if (functionName.getDb() != null) {
      // This function should not fully qualified
      throw new Exception("interval should not be qualified by database name");
    }

    RESULT = new TimestampArithmeticExpr(functionName.getFunction(), l.get(0), v, u);
  :}
  ;

literal ::=
  INTEGER_LITERAL:l
  {: RESULT = new IntLiteral(l); :}
  | LARGE_INTEGER_LITERAL:l
  {: RESULT = new LargeIntLiteral(l); :}
  | FLOATINGPOINT_LITERAL:l
  {: RESULT = new FloatLiteral(l); :}
  | DECIMAL_LITERAL:l
  {: RESULT = new DecimalLiteral(l); :}
  | STRING_LITERAL:l
  {: RESULT = new StringLiteral(l); :}
  | KW_TRUE
  {: RESULT = new BoolLiteral(true); :}
  | KW_FALSE
  {: RESULT = new BoolLiteral(false); :}
  | KW_NULL
  {: RESULT = new NullLiteral(); :}
  | UNMATCHED_STRING_LITERAL:l expr:e
  {:
    // we have an unmatched string literal.
    // to correctly report the root cause of this syntax error
    // we must force parsing to fail at this point,
    // and generate an unmatched string literal symbol
    // to be passed as the last seen token in the
    // error handling routine (otherwise some other token could be reported)
    parser.parseError("literal", SqlParserSymbols.UNMATCHED_STRING_LITERAL);
  :}
  | NUMERIC_OVERFLOW:l
  {:
    // similar to the unmatched string literal case
    // we must terminate parsing at this point
    // and generate a corresponding symbol to be reported
    parser.parseError("literal", SqlParserSymbols.NUMERIC_OVERFLOW);
  :}
  ;

function_params ::=
  STAR
  {: RESULT = FunctionParams.createStarParam(); :}
  | KW_ALL STAR
  {: RESULT = FunctionParams.createStarParam(); :}
  | expr_list:exprs
  {: RESULT = new FunctionParams(false, exprs); :}
  | KW_ALL expr_list:exprs
  {: RESULT = new FunctionParams(false, exprs); :}
  | KW_DISTINCT:distinct expr_list:exprs
  {: RESULT = new FunctionParams(true, exprs); :}
  ;

predicate ::=
  expr:e KW_IS KW_NULL
  {: RESULT = new IsNullPredicate(e, false); :}
  | KW_ISNULL LPAREN expr:e RPAREN
  {: RESULT = new IsNullPredicate(e, false); :}
  | expr:e KW_IS KW_NOT KW_NULL
  {: RESULT = new IsNullPredicate(e, true); :}
  | between_predicate:p
  {: RESULT = p; :}
  | comparison_predicate:p
  {: RESULT = p; :}
  | compound_predicate:p
  {: RESULT = p; :}
  | in_predicate:p
  {: RESULT = p; :}
  | exists_predicate:p
  {: RESULT = p; :}
  | like_predicate:p
  {: RESULT = p; :}
  | LPAREN predicate:p RPAREN
  {: RESULT = p; :}
  ;

comparison_predicate ::=
  expr:e1 EQUAL:op expr:e2
  {: RESULT = new BinaryPredicate(BinaryPredicate.Operator.EQ, e1, e2); :}
  | expr:e1 NOT EQUAL:op expr:e2
  {: RESULT = new BinaryPredicate(BinaryPredicate.Operator.NE, e1, e2); :}
  | expr:e1 LESSTHAN GREATERTHAN:op expr:e2
  {: RESULT = new BinaryPredicate(BinaryPredicate.Operator.NE, e1, e2); :}
  | expr:e1 LESSTHAN EQUAL:op expr:e2
  {: RESULT = new BinaryPredicate(BinaryPredicate.Operator.LE, e1, e2); :}
  | expr:e1 GREATERTHAN EQUAL:op expr:e2
  {: RESULT = new BinaryPredicate(BinaryPredicate.Operator.GE, e1, e2); :}
  | expr:e1 LESSTHAN:op expr:e2
  {: RESULT = new BinaryPredicate(BinaryPredicate.Operator.LT, e1, e2); :}
  | expr:e1 GREATERTHAN:op expr:e2
  {: RESULT = new BinaryPredicate(BinaryPredicate.Operator.GT, e1, e2); :}
  | expr:e1 LESSTHAN EQUAL GREATERTHAN:op expr:e2
  {: RESULT = new BinaryPredicate(BinaryPredicate.Operator.EQ, e1, e2); :}
  ;

like_predicate ::=
  expr:e1 KW_LIKE expr:e2
  {: RESULT = new LikePredicate(LikePredicate.Operator.LIKE, e1, e2); :}
  | expr:e1 KW_REGEXP expr:e2
  {: RESULT = new LikePredicate(LikePredicate.Operator.REGEXP, e1, e2); :}
  | expr:e1 KW_NOT KW_LIKE expr:e2
  {: RESULT = new CompoundPredicate(CompoundPredicate.Operator.NOT,
    new LikePredicate(LikePredicate.Operator.LIKE, e1, e2), null); :}
  | expr:e1 KW_NOT KW_REGEXP expr:e2
  {: RESULT = new CompoundPredicate(CompoundPredicate.Operator.NOT,
    new LikePredicate(LikePredicate.Operator.REGEXP, e1, e2), null); :}
  ;

// Avoid a reduce/reduce conflict with compound_predicate by explicitly
// using non_pred_expr and predicate separately instead of expr.
between_predicate ::=
  expr:e1 KW_BETWEEN non_pred_expr:e2 KW_AND expr:e3
  {: RESULT = new BetweenPredicate(e1, e2, e3, false); :}
  | expr:e1 KW_BETWEEN predicate:e2 KW_AND expr:e3
  {: RESULT = new BetweenPredicate(e1, e2, e3, false); :}
  | expr:e1 KW_NOT KW_BETWEEN non_pred_expr:e2 KW_AND expr:e3
  {: RESULT = new BetweenPredicate(e1, e2, e3, true); :}
  | expr:e1 KW_NOT KW_BETWEEN predicate:e2 KW_AND expr:e3
  {: RESULT = new BetweenPredicate(e1, e2, e3, true); :}
  ;

in_predicate ::=
  expr:e KW_IN LPAREN expr_list:l RPAREN
  {: RESULT = new InPredicate(e, l, false); :}
  | expr:e KW_NOT KW_IN LPAREN expr_list:l RPAREN
  {: RESULT = new InPredicate(e, l, true); :}
  | expr:e KW_IN subquery:s
  {: RESULT = new InPredicate(e, s, false); :}
  | expr:e KW_NOT KW_IN subquery:s
  {: RESULT = new InPredicate(e, s, true); :}
  ;

subquery ::=
  LPAREN subquery:query RPAREN
  {: RESULT = query; :}
  | LPAREN query_stmt:query RPAREN
  {: RESULT = new Subquery(query); :}
  ;

compound_predicate ::=
  expr:e1 KW_AND expr:e2
  {: RESULT = new CompoundPredicate(CompoundPredicate.Operator.AND, e1, e2); :}
  | expr:e1 KW_OR expr:e2
  {: RESULT = new CompoundPredicate(CompoundPredicate.Operator.OR, e1, e2); :}
  | KW_NOT expr:e
  {: RESULT = new CompoundPredicate(CompoundPredicate.Operator.NOT, e, null); :}
  | NOT expr:e
  {: RESULT = new CompoundPredicate(CompoundPredicate.Operator.NOT, e, null); :}
  ;

column_ref ::=
  ident:col
  {: RESULT = new SlotRef(null, col); :}
  // table_name:tblName DOT IDENT:col causes reduce/reduce conflicts
  | ident:tbl DOT ident:col
  {: RESULT = new SlotRef(new TableName(null, tbl), col); :}
  | ident:db DOT ident:tbl DOT ident:col
  {: RESULT = new SlotRef(new TableName(db, tbl), col); :}
  ;

primitive_type ::=
  KW_TINYINT
  {: RESULT = PrimitiveType.TINYINT; :}
  | KW_CHAR
  {: RESULT = PrimitiveType.VARCHAR; :}
  | KW_SMALLINT
  {: RESULT = PrimitiveType.SMALLINT; :}
  | KW_INT
  {: RESULT = PrimitiveType.INT; :}
  | KW_BIGINT
  {: RESULT = PrimitiveType.BIGINT; :}
  | KW_LARGEINT
  {: RESULT = PrimitiveType.LARGEINT; :}
  | KW_BOOLEAN
  {: RESULT = PrimitiveType.BOOLEAN; :}
  | KW_FLOAT
  {: RESULT = PrimitiveType.FLOAT; :}
  | KW_DOUBLE
  {: RESULT = PrimitiveType.DOUBLE; :}
  | KW_DATE
  {: RESULT = PrimitiveType.DATE; :}
  | KW_DATETIME
  {: RESULT = PrimitiveType.DATETIME; :}
  | KW_DECIMAL
  {: RESULT = PrimitiveType.DECIMAL; :}
  | KW_HLL
  {: RESULT = PrimitiveType.HLL; :} 
  ;

privilege_type ::=
    ident:name
    {:
        RESULT = AccessPrivilege.fromName(name);
        if (RESULT == null) {
            throw new AnalysisException("Unknown privilege type " + name);
        }
    :}
    | KW_ALL:id
    {:
        RESULT = AccessPrivilege.ALL;
    :}
    ;

privilege_list ::=
    privilege_list:l COMMA privilege_type:priv
    {:
        l.add(priv);
        RESULT = l;
    :}
    | privilege_type:priv
    {:
        RESULT = Lists.newArrayList(priv);
    :}
    ;

string_list ::=
    string_list:l COMMA STRING_LITERAL:item
    {:
        l.add(item);
        RESULT = l;
    :}
    | STRING_LITERAL:item
    {:
        RESULT = Lists.newArrayList(item);
    :}
    ;

integer_list ::=
    integer_list:l COMMA INTEGER_LITERAL:item
    {:
        l.add(item);
        RESULT = l;
    :}
    | INTEGER_LITERAL:item
    {:
        RESULT = Lists.newArrayList(item);
    :}
    ;

unsupported_stmt ::=
    KW_START KW_TRANSACTION opt_with_consistent_snapshot:v
    {:
        RESULT = new UnsupportedStmt();
    :}
    | KW_BEGIN opt_work:work
    {:
        RESULT = new UnsupportedStmt();
    :}
    | KW_COMMIT opt_work opt_chain opt_release
    {:
        RESULT = new UnsupportedStmt();
    :}
    | KW_ROLLBACK opt_work opt_chain opt_release
    {:
        RESULT = new UnsupportedStmt();
    :}
    ;

opt_with_consistent_snapshot ::=
    {:
        RESULT = null;
    :}
    | KW_WITH KW_CONSISTENT KW_SNAPSHOT
    {:
        RESULT = null;
    :}
    ;

opt_work ::=
    {:
        RESULT = null;
    :}
    | KW_WORK
    {:
        RESULT = null;
    :}
    ;

opt_chain ::=
    {:
        RESULT = null;
    :}
    | KW_AND KW_NO KW_CHAIN
    {:
        RESULT = null;
    :}
    | KW_AND KW_CHAIN
    {:
        RESULT = null;
    :}
    ;

opt_release ::=
    {:
        RESULT = null;
    :}
    | KW_RELEASE
    {:
        RESULT = null;
    :}
    | KW_NO KW_RELEASE
    {:
        RESULT = null;
    :}
    ;

// Keyword that we allow for identifiers
keyword ::=
    KW_AFTER:id
    {: RESULT = id; :}
    | KW_AGGREGATE:id
    {: RESULT = id; :}
    | KW_AUTHORS:id
    {: RESULT = id; :}
    | KW_BACKUP:id
    {: RESULT = id; :}
    | KW_BEGIN:id
    {: RESULT = id; :}
    | KW_BOOLEAN:id
    {: RESULT = id; :}
    | KW_BROKER:id
    {: RESULT = id; :}
    | KW_BACKENDS:id
    {: RESULT = id; :}
    | KW_CHAIN:id
    {: RESULT = id; :}
    | KW_CHARSET:id
    {: RESULT = id; :}
    | KW_COLUMNS:id
    {: RESULT = id; :}
    | KW_COMMENT:id
    {: RESULT = id; :}
    | KW_COMMITTED:id
    {: RESULT = id; :}
    | KW_CONSISTENT:id
    {: RESULT = id; :}
    | KW_COLLATION:id
    {: RESULT = id; :}
    | KW_COMMIT:id
    {: RESULT = id; :}
    | KW_CONNECTION:id
    {: RESULT = id; :}
    | KW_CONNECTION_ID:id
    {: RESULT = id; :}
    | KW_DATA:id
    {: RESULT = id; :}
    | KW_DATE:id
    {: RESULT = id; :}
    | KW_DATETIME:id
    {: RESULT = id; :}
    | KW_DISTINCTPC:id
    {: RESULT = id; :}
    | KW_DISTINCTPCSA:id
    {: RESULT = id; :}
    | KW_BUCKETS:id
    {: RESULT = id; :}
    | KW_FIRST:id
    {: RESULT = id; :}
    | KW_FUNCTION:id
    {: RESULT = id; :}
    | KW_END:id
    {: RESULT = id; :}
    | KW_ENGINE:id
    {: RESULT = id; :}
    | KW_ENGINES:id
    {: RESULT = id; :}
    | KW_ERRORS:id
    {: RESULT = id; :}
    | KW_EVENTS:id
    {: RESULT = id; :}
    | KW_EXTERNAL:id
    {: RESULT = id; :}
    | KW_GLOBAL:id
    {: RESULT = id; :}
    | KW_HASH:id
    {: RESULT = id; :}
    | KW_HELP:id
    {: RESULT = id; :}
    | KW_IDENTIFIED:id
    {: RESULT = id; :}
    | KW_INDEXES:id
    {: RESULT = id; :}
    | KW_ISNULL:id
    {: RESULT = id; :}
    | KW_ISOLATION:id
    {: RESULT = id; :}
    | KW_LABEL:id
    {: RESULT = id; :}
    | KW_LESS:id
    {: RESULT = id; :}
    | KW_LEVEL:id
    {: RESULT = id; :}
    | KW_LOCAL:id
    {: RESULT = id; :}
    | KW_MERGE:id
    {: RESULT = id; :}
    | KW_MODIFY:id
    {: RESULT = id; :}
    | KW_NAME:id
    {: RESULT = id; :}
    | KW_NAMES:id
    {: RESULT = id; :}
    | KW_NEGATIVE:id
    {: RESULT = id; :}
    | KW_NO:id
    {: RESULT = id; :}
    | KW_OFFSET:id
    {: RESULT = id; :}
    | KW_ONLY:id
    {: RESULT = id; :}
    | KW_OPEN:id
    {: RESULT = id; :}
    | KW_PARTITIONS:id
    {: RESULT = id; :}
    | KW_PASSWORD:id
    {: RESULT = id; :}
    | KW_PLUGIN:id
    {: RESULT = id; :}
    | KW_PLUGINS:id
    {: RESULT = id; :}
    | KW_PROC:id
    {: RESULT = id; :}
    | KW_PROCESSLIST:id
    {: RESULT = id; :}
    | KW_PROPERTIES:id
    {: RESULT = id; :}
    | KW_PROPERTY:id
    {: RESULT = id; :}
    | KW_QUERY:id
    {: RESULT = id; :}
    | KW_QUOTA:id
    {: RESULT = id; :}
    | KW_RANDOM:id
    {: RESULT = id; :}
    | KW_RECOVER:id
    {: RESULT = id; :}
    | KW_REPEATABLE:id
    {: RESULT = id; :}
    | KW_RESOURCE:id
    {: RESULT = id; :}
    | KW_RESTORE:id
    {: RESULT = id; :}
    | KW_ROLLBACK:id
    {: RESULT = id; :}
    | KW_ROLLUP:id
    {: RESULT = id; :}
    | KW_SERIALIZABLE:id
    {: RESULT = id; :}
    | KW_SESSION:id
    {: RESULT = id; :}
    | KW_SNAPSHOT:id
    {: RESULT = id; :}
    | KW_SONAME:id
    {: RESULT = id; :}
    | KW_SPLIT:id
    {: RESULT = id; :}
    | KW_START:id
    {: RESULT = id; :}
    | KW_STATUS:id
    {: RESULT = id; :}
    | KW_STORAGE:id
    {: RESULT = id; :}
    | KW_STRING:id
    {: RESULT = id; :}
    | KW_TABLES:id
    {: RESULT = id; :}
    | KW_THAN:id
    {: RESULT = id; :}
    | KW_TIMESTAMP:id
    {: RESULT = id; :}
    | KW_TRANSACTION:id
    {: RESULT = id; :}
    | KW_TRIGGERS:id
    {: RESULT = id; :}
    | KW_TYPES:id
    {: RESULT = id; :}
    | KW_UNCOMMITTED:id
    {: RESULT = id; :}
    | KW_USER:id
    {: RESULT = id; :}
    | KW_VARIABLES:id
    {: RESULT = id; :}
    | KW_VIEW:id
    {: RESULT = id; :}
    | KW_WARNINGS:id
    {: RESULT = id; :}
    | KW_WORK:id
    {: RESULT = id; :}
    | KW_CLUSTER:id
	{: RESULT = id; :}
 	| KW_CLUSTERS:id
	{: RESULT = id; :} 
    | KW_LINK:id
	{: RESULT = id; :}
    | KW_MIGRATE:id
	{: RESULT = id; :}
	| KW_MIGRATIONS:id
	{: RESULT = id; :}
	| KW_COUNT:id
	{: RESULT = id; :}
	| KW_SUM:id
	{: RESULT = id; :}
	| KW_MIN:id
	{: RESULT = id; :}
	| KW_MAX:id
	{: RESULT = id; :}
	;

// Identifier that contain keyword
ident ::=
    IDENT:id
    {:
        RESULT = id;
    :}
    | keyword:id
    {:
        RESULT = id;
    :}
    ;

// Identifier or text
ident_or_text ::=
    ident:id
    {:
        RESULT = id;
    :}
    | STRING_LITERAL:text
    {:
        RESULT = text;
    :}
    ;

// TODO(zhaochun): Select for SQL-2003 (http://savage.net.au/SQL/sql-2003-2.bnf.html)

// Specify a table derived from the result of a <table expression>.
// query_spec ::=
//     KW_SELECT opt_set_quantifier select_list table_expr
//
// opt_set_quantifier ::=
//     KW_DISTINCT
//     | KW_ALL
//     ;
//
// select_list ::=
//     STAR
//     | select_sublist
//     ;
//
// select_sublist ::=
//     derived_column
//     | qualified_star
//     ;
//
// table_expr ::=
//     from_clause where_clause group_by_clause having_clause order_by_clause limit_clause
//     ;
//
// // Specify a table derived from one or more tables.
// from_clause ::=
//     table_ref_list
//     ;
//
// table_ref_list ::=
//     table_ref
//     | table_ref_list COMMA table_ref
//     ;
//
// // Reference a table.
// table_ref ::=
//     table_primary
//     | joined_table
//     ;
//
// table_primary ::=
//     table_name
//     | subquery opt_as ident
//     | LPAREN joined_table RPAREN
//     ;
//
// opt_as ::=
//     /* Empty */
//     | KW_AS
//     ;
//
// // Specify a table.
// // TODO(zhaochun): Do not support EXCEPT INTERSECT and joined table
// query_expr_body ::=
//     query_term
//     | query_expr_body KW_UNION opt_set_quantifier query_term;
//     ;
//
// query_term ::=
//     query_spec
//     | LPAREN query_expr_body RPAREN
//     ;
//
// // Specify a scalar value, a row, or a table derived from a <query expression>.
// subquery ::=
//     LPAREN query_expr_body RPAREN;
