fn main() {
    println!("Hello, world!");
}

#[cfg(test)]
mod tests {
    #[test]
    fn addition() {
        assert_eq!(1 + 1, 3);
    }
}