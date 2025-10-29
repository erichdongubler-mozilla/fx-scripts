use std::io::Read as _;

use chumsky::Parser as _;

mod front {
    pub(crate) mod ticktick_summary {
        use chumsky::{
            Parser, error,
            extra::Full,
            prelude::{any, custom, group, just},
            span::SimpleSpan,
            text::{inline_whitespace, newline},
        };
        use petgraph::graph::NodeIndex;

        use crate::mid::{Task, TaskDb, TaskPriority, TaskProperties, TaskState};

        #[derive(Clone, Debug)]
        pub(crate) struct TaskEntry<'a> {
            inner: Task<'a>,
            name_span: SimpleSpan,
            parent: Option<(&'a str, SimpleSpan)>,
            children: Vec<TaskEntry<'a>>,
        }

        pub fn task_entries<'a>()
        -> impl Parser<'a, &'a str, TaskDb<'a>, Full<error::Rich<'a, char>, (), ()>> {
            let status_section = |priority, name, state| {
                group((just("###     "), just(name), newline()))
                    .ignore_then(tasks(priority, state).map(|tasks| tasks.into_iter()))
            };
            let priority_section = |priority: TaskPriority| {
                group((just("## "), just(priority.ticktick_ident()), newline()))
                    .ignore_then(group((
                        status_section(priority, "Completed", TaskState::Completed).or_not(),
                        status_section(priority, "Won't Do", TaskState::WontDo).or_not(),
                        status_section(priority, "Undone", TaskState::Undone).or_not(),
                    )))
                    .map(|(completed, wont_do, undone)| {
                        [completed, wont_do, undone].into_iter().flatten().flatten()
                    })
            };
            let title = just("# ")
                .ignore_then(any().and_is(newline().not()).repeated().to_slice())
                .then_ignore(group((newline(), filler())));

            group((
                title,
                priority_section(TaskPriority::High).or_not(),
                priority_section(TaskPriority::Medium).or_not(),
                priority_section(TaskPriority::Low).or_not(),
                priority_section(TaskPriority::None).or_not(),
            ))
            .map(|(title, high, medium, low, none)| {
                let mut task_db = TaskDb::new(title);
                let task_entries = [high, medium, low, none].into_iter().flatten().flatten();
                for task_entry in task_entries {
                    task_db.add_ticktick_summary_task_entry(task_entry);
                }
                task_db
            })
        }

        fn filler<'a>() -> impl Parser<'a, &'a str, (), Full<error::Rich<'a, char>, (), ()>> {
            inline_whitespace().then(newline()).repeated().to(())
        }

        fn tasks<'a>(
            priority: TaskPriority,
            state: TaskState,
        ) -> impl Parser<'a, &'a str, Vec<TaskEntry<'a>>, Full<error::Rich<'a, char>, (), ()>>
        {
            let name_and_parent = |indent| {
                group((just("    ").repeated().exactly(indent), just("- ")))
                    .ignore_then(group((
                        any()
                            .and_is(just(" /").ignored().or(newline()).not())
                            .repeated()
                            .to_slice()
                            .map_with(|name, ex| (name, ex.span())),
                        just(" /")
                            .ignore_then(
                                any()
                                    .and_is(newline().not())
                                    .repeated()
                                    .to_slice()
                                    .map_with(|parent, ex| (parent, ex.span())),
                            )
                            .or_not(),
                    )))
                    .then_ignore(group((newline(), filler().or_not())))
            };

            custom(move |input| {
                let children = {
                    let mut children_stack = vec![vec![]];
                    let mut indent = 1;
                    let children = loop {
                        if let Some(((name, name_span), parent)) =
                            input.parse(name_and_parent(indent).or_not())?
                        {
                            let properties = if indent == 1 {
                                Some(TaskProperties { priority, state })
                            } else {
                                None
                            };
                            children_stack.last_mut().unwrap().push(TaskEntry {
                                inner: Task { properties, name },
                                name_span,
                                parent,
                                children: Vec::new(),
                            });
                            children_stack.push(Vec::new());
                            indent += 1;
                        } else {
                            let new_children = children_stack.pop().unwrap();
                            indent -= 1;
                            if let Some(children) = children_stack.last_mut() {
                                children.last_mut().unwrap().children = new_children;
                            } else if indent == 0 {
                                break new_children;
                            }
                        }
                    };
                    assert!(children_stack.is_empty());
                    children
                };
                Ok(children)
            })
        }

        impl<'a> crate::mid::TaskDb<'a> {
            pub fn add_ticktick_summary_task_entry(&mut self, task_entry: TaskEntry<'a>) {
                let _ = self.add_task_entry_impl(task_entry);
            }

            fn add_task_entry_impl(&mut self, task_entry: TaskEntry<'a>) -> NodeIndex {
                let node_id = self.add_node(task_entry.inner);

                if let Some(name) = task_entry.parent.map(|p| p.0) {
                    let parent_node_id = self.add_node(Task {
                        properties: None,
                        name,
                    });
                    self.task_graph.add_edge(parent_node_id, node_id, ());
                }

                for child in task_entry.children {
                    let child_id = self.add_task_entry_impl(child);
                    self.task_graph.add_edge(node_id, child_id, ());
                }

                node_id
            }

            fn add_node(&mut self, task: Task<'a>) -> NodeIndex {
                let Self {
                    title: _,
                    graph_nodes_by_task_name,
                    task_graph,
                } = self;

                let name = task.name;

                if let Some(&node_id) = graph_nodes_by_task_name.get(name) {
                    let task_already_in_graph = task_graph.node_weight_mut(node_id).unwrap();
                    let new_properties =
                        match [task_already_in_graph.properties.take(), task.properties] {
                            [None, None] => None,
                            [Some(existing), Some(incoming)] => {
                                assert_eq!(existing, incoming);
                                Some(existing)
                            }
                            [None, winner @ Some(_)] | [winner @ Some(_), None] => winner,
                        };
                    task_already_in_graph.properties = new_properties;
                    node_id
                } else {
                    let new_node_id = task_graph.add_node(task);
                    graph_nodes_by_task_name.insert(name, new_node_id);
                    new_node_id
                }
            }
        }

        impl crate::mid::TaskPriority {
            pub(crate) fn ticktick_ident(&self) -> &'static str {
                match self {
                    TaskPriority::High => "High",
                    TaskPriority::Medium => "Medium",
                    TaskPriority::Low => "Low",
                    TaskPriority::None => "None",
                }
            }
        }
    }
}

pub(crate) mod mid {
    use petgraph::{
        Direction,
        graph::{DiGraph, NodeIndex},
    };
    use std::{collections::BTreeMap, io};

    #[derive(Clone, Debug)]
    pub(crate) struct Task<'a> {
        pub properties: Option<TaskProperties>,
        pub name: &'a str,
    }

    #[derive(Clone, Debug, Eq, PartialEq)]
    pub(crate) struct TaskProperties {
        pub priority: TaskPriority,
        pub state: TaskState,
    }

    #[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
    pub(crate) enum TaskPriority {
        High,
        Medium,
        Low,
        None,
    }

    #[derive(Clone, Copy, Debug, Eq, PartialEq)]
    pub(crate) enum TaskState {
        Undone,
        Completed,
        WontDo,
    }

    pub(crate) struct TaskDb<'a> {
        pub title: &'a str,
        // pub date_range: ()
        pub graph_nodes_by_task_name: BTreeMap<&'a str, NodeIndex>,
        pub task_graph: DiGraph<Task<'a>, ()>,
    }

    impl<'a> TaskDb<'a> {
        pub fn new(title: &'a str) -> Self {
            Self {
                title,
                graph_nodes_by_task_name: Default::default(),
                task_graph: Default::default(),
            }
        }

        pub fn print_dot(&self) {
            use petgraph::dot::*;
            println!(
                "{:?}",
                Dot::with_config(&self.task_graph, &[Config::EdgeNoLabel])
            );
        }

        pub fn print_markdown_report(&self) {
            use io::Write as _;

            let mut root_tasks_by_priority = BTreeMap::new();
            for root_task_idx in self.task_graph.externals(petgraph::Direction::Incoming) {
                let root_task = self.task_graph.node_weight(root_task_idx).unwrap();
                root_tasks_by_priority
                    .entry(
                        root_task
                            .properties
                            .as_ref()
                            .map(|ps| ps.priority)
                            .unwrap_or(TaskPriority::None),
                    )
                    .or_insert_with(Vec::new)
                    .push(root_task_idx);
            }

            let mut stdout = io::stdout().lock();

            writeln!(&mut stdout, "# {}", self.title).unwrap();
            if root_tasks_by_priority.is_empty() {
                writeln!(&mut stdout, "\nNothing. Eek!").unwrap();
                return;
            }
            for (priority, root_tasks) in root_tasks_by_priority {
                if root_tasks.is_empty() {
                    continue;
                }
                write!(&mut stdout, "\n## {}\n\n", priority.ticktick_ident()).unwrap();
                for &task_idx in &root_tasks {
                    fn print_task_and_children(
                        stdout: &mut io::StdoutLock<'_>,
                        indent: u16,
                        task_graph: &DiGraph<Task<'_>, ()>,
                        task_idx: NodeIndex,
                    ) {
                        let task = task_graph.node_weight(task_idx).unwrap();
                        let state = task
                            .properties
                            .as_ref()
                            .map_or(TaskState::Undone, |ps| ps.state);
                        let checkbox = match state {
                            TaskState::Undone => "[ ]",
                            TaskState::Completed => "[x]",
                            // TODO: Should we ignore these?
                            TaskState::WontDo => "[nope]",
                        };
                        for _ in 0..indent {
                            write!(stdout, "  ").unwrap();
                        }
                        writeln!(stdout, "- {checkbox} {}", task.name).unwrap();

                        for child_idx in
                            task_graph.neighbors_directed(task_idx, Direction::Outgoing)
                        {
                            print_task_and_children(stdout, indent + 1, task_graph, child_idx);
                        }
                    }
                    print_task_and_children(&mut stdout, 0, &self.task_graph, task_idx);
                }
            }
        }
    }
}

/// Convert summary output from Ticktick (in Markdown) from `stdin` into a report that Erich can use
/// for his own reporting at Mozilla, printed to `stdout`.
#[derive(Clone, Debug, clap::Parser)]
#[clap(about)]
struct Cli {
    #[clap(long = "output-fmt")]
    output_format: OutputFormat,
}

#[derive(Clone, Copy, Debug, clap::ValueEnum)]
enum OutputFormat {
    Graphviz,
    Markdown,
}

fn main() {
    env_logger::init();

    let Cli { output_format } = clap::Parser::parse();

    let stdin = {
        let mut buf = String::new();
        std::io::stdin().lock().read_to_string(&mut buf).unwrap();
        buf
    };

    let task_db = front::ticktick_summary::task_entries()
        .parse(&*stdin)
        .into_result()
        .unwrap();


    match output_format {
        OutputFormat::Graphviz => task_db.print_dot(),
        OutputFormat::Markdown => task_db.print_markdown_report(),
    }
}
